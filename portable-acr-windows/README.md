# Portable Windows Golden Disk in ACR

This folder provides a reusable procedure for distributing a configured
[`dockurr/windows`](https://github.com/dockur/windows) guest through Azure
Container Registry (ACR).

The procedure keeps two different artifacts:

1. A Linux container image that supplies QEMU and the Windows launcher.
2. A persistent `/storage` directory containing the installed Windows virtual
   disk and machine configuration.

The runtime is stored as a normal container image. The stopped golden storage
is compressed and stored as a generic OCI artifact. Kubernetes cannot mount
that artifact directly, so a temporary import Job restores it into a golden
PVC before the StatefulSet is deployed.

No subscription, cluster, namespace, or ACR is hardcoded in the scripts or
manifests. Environment-specific values belong in the ignored `config.psd1`.

## Artifact flow

```text
Pinned dockurr/windows digest
              |
              | az acr import
              v
<acr>/windows/runtime:<derived-tag>

<source-namespace>/<source-golden-pvc> (unmounted)
              |
              | export Job: sparse tar + zstd + oras push
              v
<acr>/windows/golden-disk:<artifact-tag>
              |
              | import Job: oras pull + checksum + extract
              v
<target-namespace>/<target-golden-pvc>
              |
              | Kubernetes PVC dataSource cloning
              v
<target-namespace>/storage-windows-0
```

## Prerequisites

- PowerShell 7 or Windows PowerShell 5.1.
- Azure CLI authenticated to the configured subscription.
- `kubectl` access to the configured AKS cluster.
- Permission to import/build in ACR, create repository-scoped ACR tokens, and
  grant the AKS kubelet identity `AcrPull`.
- Linux nodes with `/dev/kvm` and `/dev/net/tun`.
- A CSI StorageClass that supports PVC cloning.
- Enough temporary storage for the compressed archive.
- The source golden PVC must not be mounted while it is exported.
- Appropriate Windows licensing and activation rights in every target
  environment.

The disk contains the existing Windows account, credential hashes, machine
identity, applications, and data. Sanitize it before sharing and communicate
the Windows login through an approved secret-sharing channel. Changing a
Kubernetes Secret does not change credentials inside an already-installed
guest.

## Configure an environment

Run commands from this folder:

```powershell
Set-Location .\portable-acr-windows
Copy-Item .\config.example.psd1 .\config.psd1
```

Edit `config.psd1` and replace every angle-bracket placeholder:

| Setting | Purpose |
|---|---|
| `SubscriptionId` | Azure subscription containing AKS and ACR |
| `ResourceGroup` | Resource group containing the AKS cluster |
| `ClusterName` | AKS resource name |
| `KubectlContext` | Local kubeconfig context for that cluster |
| `RegistryName` | ACR resource name, without `.azurecr.io` |
| `RegistryLoginServer` | Complete ACR login server |
| `RuntimeSource` | Source runtime pinned by a full SHA-256 digest |
| `RuntimeRepository` | Destination ACR runtime repository |
| `TransferRepository` | Destination ACR helper repository |
| `ArtifactRepository` | Destination generic OCI artifact repository |
| `ArtifactTag` | Immutable version assigned to this golden disk |
| `SourceNamespace` / `SourcePvc` | Unmounted source golden storage |
| `TargetNamespace` / `TargetPvc` | Destination golden storage |
| `StorageClass` | CSI StorageClass supporting PVC cloning |
| `StorageSize` | Golden and replica PVC capacity |
| `StagingSize` | Temporary export/import PVC capacity |
| `DiskSize` | `dockurr/windows` virtual disk size, such as `64G` |
| `Replicas` | Initial validation replica count |

To find the exact digest used by an existing source pod:

```powershell
$config = Import-PowerShellDataFile .\config.psd1

kubectl --context $config.KubectlContext `
  --namespace $config.SourceNamespace `
  get pod windows-0 `
  -o jsonpath='{.status.containerStatuses[0].imageID}'
```

Set `RuntimeSource` to a fully qualified value such as:

```text
docker.io/dockurr/windows@sha256:<64-hex-digest>
```

The scripts stop before changing Azure or Kubernetes if a required value is
missing or still contains an angle-bracket placeholder.

## Procedure

### 1. Publish the runtime and transfer helper

```powershell
.\scripts\01-PublishImages.ps1
```

This imports the pinned runtime, derives an immutable-looking source tag from
its digest, builds the transfer helper, and grants the configured AKS kubelet
identity `AcrPull` on the configured ACR.

### 2. Export the stopped golden PVC to ACR

```powershell
.\scripts\02-ExportGoldenDisk.ps1
```

The script refuses to continue if any pod mounts `SourcePvc`. It creates a
temporary staging PVC and a one-day, repository-scoped ACR credential. The
credential, Kubernetes Secret, Job, and staging PVC are removed after a
successful upload.

The export preserves sparse files and records a SHA-256 checksum plus source
metadata. Never export a replica PVC while its Windows guest is running.

### 3. Import the golden disk

```powershell
.\scripts\03-ImportGoldenDisk.ps1
```

The configured destination PVC must not already exist. The script creates the
target namespace, pulls the artifact, validates its checksum, restores
`/storage`, and retains the populated golden PVC.

### 4. Deploy a validation replica

```powershell
.\scripts\04-DeployWindows.ps1
```

The StatefulSet clones the imported golden PVC for each replica and uses the
mirrored runtime pinned by digest.

### 5. Verify

```powershell
.\scripts\05-Verify.ps1
```

For an interactive RDP test:

```powershell
$config = Import-PowerShellDataFile .\config.psd1

kubectl --context $config.KubectlContext `
  --namespace $config.TargetNamespace `
  port-forward pod/windows-0 3390:3389
```

Connect Remote Desktop to `127.0.0.1:3390`.

After validation, scale explicitly:

```powershell
kubectl --context $config.KubectlContext `
  --namespace $config.TargetNamespace `
  scale statefulset/windows --replicas 2
```

## Sharing with another AKS cluster

Give the target operator this folder without your local `config.psd1`. The
operator creates their own file from `config.example.psd1`.

If the target cluster uses the same ACR, grant its kubelet identity `AcrPull`:

```powershell
$config = Import-PowerShellDataFile .\config.psd1
$acrId = az acr show `
  --name $config.RegistryName `
  --query id `
  --output tsv

az aks update `
  --subscription $config.SubscriptionId `
  --resource-group $config.ResourceGroup `
  --name $config.ClusterName `
  --attach-acr $acrId
```

The target operator then runs steps 3 through 5. Steps 1 and 2 only need to be
repeated when publishing a new runtime, transfer helper, or golden disk.

For non-AKS Kubernetes, configure registry pull access separately and ensure
the CSI driver supports PVC cloning. The cluster must expose KVM and TUN
devices to privileged Linux pods.

## Publish a new golden-disk version

Use a new immutable `ArtifactTag` instead of overwriting a distributed tag:

1. Shut down the builder or guest using the source golden PVC.
2. Change `ArtifactTag` in the local `config.psd1`.
3. Run `02-ExportGoldenDisk.ps1`.
4. Import the new tag into a new target namespace, or intentionally remove and
   recreate the old destination resources.

## Cleanup

Load the local configuration:

```powershell
. .\scripts\Common.ps1
$config = Get-PortableWindowsConfig
$runtimeTag = Get-RuntimeTag -Config $config
```

Delete the target namespace and its disks:

```powershell
kubectl --context $config.KubectlContext `
  delete namespace $config.TargetNamespace
```

Remove published artifacts only after confirming no cluster depends on them:

```powershell
az acr repository delete `
  --name $config.RegistryName `
  --image "$($config.ArtifactRepository):$($config.ArtifactTag)" `
  --yes

az acr repository delete `
  --name $config.RegistryName `
  --image "$($config.RuntimeRepository):$runtimeTag" `
  --yes

az acr repository delete `
  --name $config.RegistryName `
  --image "$($config.TransferRepository):$($config.TransferTag)" `
  --yes
```

Deleting a namespace or PVC permanently deletes its Azure Disk when the
StorageClass reclaim policy is `Delete`.
