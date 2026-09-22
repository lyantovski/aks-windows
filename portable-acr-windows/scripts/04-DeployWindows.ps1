[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-PortableWindowsConfig
Initialize-PortableWindowsSession -Config $config
Assert-ConfigValues -Config $config -Names @(
    'TargetNamespace',
    'TargetPvc',
    'StorageClass',
    'StorageSize',
    'DiskSize',
    'Replicas'
)

Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'get', "pvc/$($config.TargetPvc)"
)

Apply-ManifestTemplate `
    -Path (Join-Path $PSScriptRoot '..\manifests\windows.yaml') `
    -Config $config `
    -Replacements @{
        NAMESPACE = $config.TargetNamespace
        REPLICAS = $config.Replicas
        RUNTIME_IMAGE = Get-RuntimeImage -Config $config
        STORAGE_CLASS = $config.StorageClass
        STORAGE_SIZE = $config.StorageSize
        DISK_SIZE = $config.DiskSize
        TARGET_PVC = $config.TargetPvc
    }

Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'rollout', 'status', 'statefulset/windows',
    '--timeout', '30m'
)

Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'get', 'statefulset,pods,pvc',
    '--output', 'wide'
)
