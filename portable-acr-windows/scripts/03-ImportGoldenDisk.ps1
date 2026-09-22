[CmdletBinding()]
param(
    [switch] $KeepStagingPvc
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-PortableWindowsConfig
Initialize-PortableWindowsSession -Config $config
Assert-ConfigValues -Config $config -Names @(
    'TargetNamespace',
    'TargetPvc',
    'StorageClass',
    'StorageSize',
    'StagingSize',
    'ArtifactRepository',
    'ArtifactTag'
)

$namespaceManifest = @{
    apiVersion = 'v1'
    kind = 'Namespace'
    metadata = @{
        name = $config.TargetNamespace
    }
} | ConvertTo-Json -Depth 4

$namespaceManifest |
    & kubectl --context $config.KubectlContext apply -f -
if ($LASTEXITCODE -ne 0) {
    throw "Creating namespace '$($config.TargetNamespace)' failed."
}

$existingPvc = Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'get', "pvc/$($config.TargetPvc)",
    '--ignore-not-found',
    '--output', 'name'
) -Capture
if ($existingPvc) {
    throw "Destination PVC '$($config.TargetNamespace)/$($config.TargetPvc)' already exists. Refusing to overwrite it."
}

Invoke-Native az @(
    'acr', 'manifest', 'show-metadata',
    '--registry', $config.RegistryName,
    '--name', "$($config.ArtifactRepository):$($config.ArtifactTag)",
    '--output', 'none'
)

$credential = $null
$succeeded = $false
try {
    $credential = New-OrasCredential `
        -Config $config `
        -Namespace $config.TargetNamespace `
        -Access pull

    Apply-ManifestTemplate `
        -Path (Join-Path $PSScriptRoot '..\manifests\import-job.yaml') `
        -Config $config `
        -Replacements @{
            TARGET_PVC = $config.TargetPvc
            NAMESPACE = $config.TargetNamespace
            STORAGE_CLASS = $config.StorageClass
            STORAGE_SIZE = $config.StorageSize
            STAGING_SIZE = $config.StagingSize
            TRANSFER_IMAGE = Get-TransferImage -Config $config
            ACR_REGISTRY = $config.RegistryLoginServer
            ARTIFACT_REPOSITORY = $config.ArtifactRepository
            ARTIFACT_TAG = $config.ArtifactTag
        }

    Wait-ForJob `
        -Config $config `
        -Namespace $config.TargetNamespace `
        -Name portable-windows-import

    $succeeded = $true
}
finally {
    if ($null -ne $credential) {
        Remove-OrasCredential -Config $config -Credential $credential
    }

    if ($succeeded) {
        & kubectl --context $config.KubectlContext `
            --namespace $config.TargetNamespace `
            delete job portable-windows-import `
            --ignore-not-found

        if (-not $KeepStagingPvc) {
            & kubectl --context $config.KubectlContext `
                --namespace $config.TargetNamespace `
                delete pvc portable-windows-import-staging `
                --ignore-not-found
        }
    }
}

Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'get', "pvc/$($config.TargetPvc)",
    '--output', 'wide'
)
