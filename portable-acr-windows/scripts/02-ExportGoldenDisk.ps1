[CmdletBinding()]
param(
    [switch] $KeepStagingPvc
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$config = Get-PortableWindowsConfig
Initialize-PortableWindowsSession -Config $config
Assert-ConfigValues -Config $config -Names @(
    'SourceNamespace',
    'SourcePvc',
    'StorageClass',
    'StagingSize',
    'ArtifactRepository',
    'ArtifactTag'
)

Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.SourceNamespace,
    'get', "pvc/$($config.SourcePvc)"
)

$podsJson = Invoke-Native kubectl @(
    '--context', $config.KubectlContext,
    '--namespace', $config.SourceNamespace,
    'get', 'pods',
    '--output', 'json'
) -Capture | ConvertFrom-Json

$mountingPods = @(
    $podsJson.items | Where-Object {
        @(
            $_.spec.volumes | Where-Object {
                $_.PSObject.Properties.Name -contains 'persistentVolumeClaim' -and
                $_.persistentVolumeClaim.claimName -eq $config.SourcePvc
            }
        ).Count -gt 0
    } | ForEach-Object {
        $_.metadata.name
    }
)

if ($mountingPods.Count -gt 0) {
    throw "Source PVC '$($config.SourcePvc)' is mounted by: $($mountingPods -join ', '). Stop those pods before exporting."
}

& kubectl --context $config.KubectlContext `
    --namespace $config.SourceNamespace `
    delete job portable-windows-export `
    --ignore-not-found

$credential = $null
$succeeded = $false
try {
    $credential = New-OrasCredential `
        -Config $config `
        -Namespace $config.SourceNamespace `
        -Access push

    Apply-ManifestTemplate `
        -Path (Join-Path $PSScriptRoot '..\manifests\export-job.yaml') `
        -Config $config `
        -Replacements @{
            NAMESPACE = $config.SourceNamespace
            STORAGE_CLASS = $config.StorageClass
            STAGING_SIZE = $config.StagingSize
            TRANSFER_IMAGE = Get-TransferImage -Config $config
            ACR_REGISTRY = $config.RegistryLoginServer
            ARTIFACT_REPOSITORY = $config.ArtifactRepository
            ARTIFACT_TAG = $config.ArtifactTag
            SOURCE_PVC = $config.SourcePvc
            RUNTIME_IMAGE = Get-RuntimeImage -Config $config
        }

    Wait-ForJob `
        -Config $config `
        -Namespace $config.SourceNamespace `
        -Name portable-windows-export

    Invoke-Native az @(
        'acr', 'manifest', 'show-metadata',
        '--registry', $config.RegistryName,
        '--name', "$($config.ArtifactRepository):$($config.ArtifactTag)",
        '--output', 'table'
    )
    $succeeded = $true
}
finally {
    if ($null -ne $credential) {
        Remove-OrasCredential -Config $config -Credential $credential
    }

    if ($succeeded) {
        & kubectl --context $config.KubectlContext `
            --namespace $config.SourceNamespace `
            delete job portable-windows-export `
            --ignore-not-found

        if (-not $KeepStagingPvc) {
            & kubectl --context $config.KubectlContext `
                --namespace $config.SourceNamespace `
                delete pvc portable-windows-export-staging `
                --ignore-not-found
        }
    }
}
