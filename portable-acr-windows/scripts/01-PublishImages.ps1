[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-PortableWindowsConfig
Initialize-PortableWindowsSession -Config $config
Assert-ConfigValues -Config $config -Names @(
    'RuntimeSource',
    'RuntimeRepository',
    'TransferRepository',
    'TransferTag'
)
$runtimeTag = Get-RuntimeTag -Config $config

Write-Host "Importing the pinned dockurr/windows runtime into ACR..."
Invoke-Native az @(
    'acr', 'import',
    '--name', $config.RegistryName,
    '--source', $config.RuntimeSource,
    '--image', "$($config.RuntimeRepository):$runtimeTag",
    '--force',
    '--output', 'none'
)

Write-Host "Building the transfer helper in ACR..."
$transferPath = (Resolve-Path (Join-Path $PSScriptRoot '..\transfer')).Path
Invoke-Native az @(
    'acr', 'build',
    '--registry', $config.RegistryName,
    '--image', "$($config.TransferRepository):$($config.TransferTag)",
    '--platform', 'linux/amd64',
    $transferPath
)

Write-Host "Granting the AKS kubelet identity AcrPull on the registry..."
$registryId = Invoke-Native az @(
    'acr', 'show',
    '--name', $config.RegistryName,
    '--query', 'id',
    '--output', 'tsv'
) -Capture

Invoke-Native az @(
    'aks', 'update',
    '--resource-group', $config.ResourceGroup,
    '--name', $config.ClusterName,
    '--attach-acr', $registryId,
    '--output', 'none'
)

Write-Host "Published images:"
Invoke-Native az @(
    'acr', 'repository', 'show-tags',
    '--name', $config.RegistryName,
    '--repository', $config.RuntimeRepository,
    '--output', 'table'
)
Invoke-Native az @(
    'acr', 'repository', 'show-tags',
    '--name', $config.RegistryName,
    '--repository', $config.TransferRepository,
    '--output', 'table'
)
