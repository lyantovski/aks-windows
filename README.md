# Windows on AKS

This repository deploys Windows 11 inside Linux containers by using
[`dockurr/windows`](https://github.com/dockur/windows). Each StatefulSet
replica receives its own Azure Disk cloned from the preinstalled
`windows-pvc` golden disk.

The Kubernetes manifests are stored in the `k8s-scripts` folder:

- `k8s-scripts/k8s-windows-golden.yaml` creates the golden Windows disk.
- `k8s-scripts/k8s-windows.yaml` deploys the Windows StatefulSet.

To distribute the installed Windows disk through Azure Container Registry and
restore it in another Kubernetes namespace or cluster, use the self-contained
workflow in `portable-acr-windows/README.md`. It mirrors the runtime container
and stores the stopped `/storage` contents as a separate generic OCI artifact.

## Prerequisites

- An AKS cluster with Linux nodes that expose `/dev/kvm` and `/dev/net/tun`.
- The Azure Disk CSI driver and a default `disk.csi.azure.com` StorageClass.
- Enough node capacity for the configured 500 millicore / 2 GiB request and
  4 CPU / 8 GiB limit per Windows guest.
- A `windows` namespace:

  ```powershell
  kubectl create namespace windows --dry-run=client -o yaml |
    kubectl apply -f -
  ```

## Create the Windows credentials Secret

The manifest reads the Windows username and password from the
`windows-credentials` Kubernetes Secret. Do not put the password directly in
`k8s-scripts/k8s-windows.yaml` or commit it to Git.

These are credentials for a local administrator account inside the Windows
guest. They are not related to the developer workstation, the Linux `root`
account, or an AKS identity.

Create a simple username and password:

```powershell
kubectl create secret generic windows-credentials `
  --namespace windows `
  --from-literal=username=admin `
  --from-literal=password='<choose-a-strong-password>' `
  --dry-run=client `
  -o yaml |
  kubectl apply -f -
```

Confirm that the Secret exists without displaying its values:

```powershell
kubectl get secret windows-credentials --namespace windows
```

When you need to retrieve the current login for RDP:

```powershell
$secret = kubectl get secret windows-credentials `
  --namespace windows `
  -o json | ConvertFrom-Json

$username = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String($secret.data.username)
)
$password = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String($secret.data.password)
)

Write-Output "Username: $username"
Write-Output "Password: $password"
```

This prints the password in the terminal. Clear the terminal after copying it.

The command above may be retained in PowerShell history. For shared
workstations or production environments, inject the values from an approved
secret manager instead of entering the password directly on the command line.

The `admin` account created by `dockurr/windows` is placed in the local Windows
Administrators group and has administrative privileges inside the guest.

## Credential behavior

`dockurr/windows` uses `USERNAME` and `PASSWORD` while installing Windows.
Updating the Kubernetes Secret or restarting an existing pod does **not**
change credentials inside an already-installed Windows guest.

## Build the golden Windows disk

The bootstrap manifest creates:

- The `windows-pvc` golden Azure Disk.
- A temporary `windows-golden-builder` pod.
- A single Windows installation using `windows-credentials`.

Apply it before the main manifest:

```powershell
kubectl apply -f .\k8s-scripts\k8s-windows-golden.yaml

kubectl wait pod/windows-golden-builder `
  --namespace windows `
  --for=condition=Ready `
  --timeout=45m
```

Follow the installation if required:

```powershell
kubectl logs windows-golden-builder --namespace windows --follow
```

The installation is complete when the log contains:

```text
Windows started successfully
```

Stop the builder cleanly and retain its installed `windows-pvc` disk:

```powershell
kubectl delete pod windows-golden-builder --namespace windows
kubectl wait pod/windows-golden-builder `
  --namespace windows `
  --for=delete `
  --timeout=5m
```

> Do not run
> `kubectl delete -f .\k8s-scripts\k8s-windows-golden.yaml`. That command also
> deletes `windows-pvc`, which is the golden disk needed by the main workload.

## Switch to the main StatefulSet

After the builder pod has stopped, apply the main manifest:

```powershell
kubectl apply -f .\k8s-scripts\k8s-windows.yaml
kubectl rollout status statefulset/windows `
  --namespace windows `
  --timeout 20m
```

The manifest creates:

- `windows-0` with PVC `storage-windows-0`
- `windows-1` with PVC `storage-windows-1`
- One independent Azure Disk per replica
- A headless service for StatefulSet identity
- A ClusterIP service for HTTP, RDP, UDP, and VNC

## Rebuild the golden disk or change credentials

This procedure deletes the installed Windows guests and their disks. Back up
anything important first.

1. Stop and remove the StatefulSet:

   ```powershell
   kubectl scale statefulset windows --namespace windows --replicas 0
   kubectl wait pod --namespace windows --selector app=windows `
     --for=delete --timeout=5m
   kubectl delete statefulset windows --namespace windows
   ```

2. Delete all replica disks and the old golden disk:

   ```powershell
   kubectl delete pvc --namespace windows `
     --selector app=windows,role=replica-storage
   kubectl delete pvc windows-pvc --namespace windows
   ```

3. Update `windows-credentials` as described above.
4. Repeat **Build the golden Windows disk**.
5. Repeat **Switch to the main StatefulSet**.

Deleting `windows-pvc` permanently deletes the golden Windows disk when the
default StorageClass uses a `Delete` reclaim policy.

## Scale

```powershell
kubectl scale statefulset windows --namespace windows --replicas 3
```

Every new ordinal receives a separate Azure Disk cloned from `windows-pvc`.
It boots the preinstalled Windows image instead of repeating the 25-30 minute
installation.

StatefulSet PVCs are retained when scaling down. Scaling back up reuses each
replica's existing disk:

```powershell
kubectl scale statefulset windows --namespace windows --replicas 1
kubectl scale statefulset windows --namespace windows --replicas 2
```

## Verify

```powershell
kubectl get statefulset,pods,pvc --namespace windows -o wide
kubectl logs windows-0 --namespace windows
kubectl logs windows-1 --namespace windows
```

A ready guest logs:

```text
Windows started successfully
```

The RDP readiness probe keeps the pod unready until TCP port 3389 is reachable.

## Retrieve individual pod addresses

The `windows` ClusterIP service load-balances connections across all ready
replicas. Use the pod IP or StatefulSet DNS name when a connection must target
a specific Windows guest:

```powershell
kubectl get pods --namespace windows -o wide
```

Within the cluster, the stable DNS names are:

```text
windows-0.windows-headless.windows.svc.cluster.local
windows-1.windows-headless.windows.svc.cluster.local
```

## Connect with RDP through port forwarding

Forward local TCP port 3389 directly to the first pod:

```powershell
kubectl port-forward pod/windows-0 `
  --namespace windows `
  3389:3389
```

Keep that command running and connect Remote Desktop to:

```text
127.0.0.1:3389
```

Use a different local port when forwarding another replica because only one
process can listen on local port 3389:

```powershell
kubectl port-forward pod/windows-1 `
  --namespace windows `
  3390:3389
```

Connect the second guest at `127.0.0.1:3390`.
