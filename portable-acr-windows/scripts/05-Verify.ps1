[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-PortableWindowsConfig
Initialize-PortableWindowsSession -Config $config
Assert-ConfigValues -Config $config -Names @(
    'TargetNamespace',
    'ArtifactRepository',
    'ArtifactTag',
    'Replicas'
)

Write-Host "Verifying ACR artifacts..."
Invoke-Native az @(
    'acr', 'manifest', 'show-metadata',
    '--registry', $config.RegistryName,
    '--name', "$($config.ArtifactRepository):$($config.ArtifactTag)",
    '--output', 'table'
)

Write-Host "Verifying Kubernetes resources..."
Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'get', 'statefulset,pods,pvc,services',
    '--output', 'wide'
)

$readyReplicas = Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.TargetNamespace,
    'get', 'statefulset/windows',
    '--output', 'jsonpath={.status.readyReplicas}'
) -Capture

if ([int]$readyReplicas -ne [int]$config.Replicas) {
    throw "Expected $($config.Replicas) ready replica(s), but found '$readyReplicas'."
}

for ($ordinal = 0; $ordinal -lt [int]$config.Replicas; $ordinal++) {
    $pod = "windows-$ordinal"
    $logs = Invoke-Native kubectl @(
        '--context', $config.KubectlContext,
        '--namespace', $config.TargetNamespace,
        'logs', $pod
    ) -Capture

    if ($logs -notmatch 'Windows started successfully') {
        throw "Pod '$pod' is ready, but its logs do not contain the Windows startup confirmation."
    }
    Write-Host "${pod}: Windows started successfully."
}
