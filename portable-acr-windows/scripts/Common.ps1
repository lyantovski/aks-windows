Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PortableWindowsConfig {
    $configPath = Join-Path $PSScriptRoot '..\config.psd1'
    if (-not (Test-Path $configPath)) {
        throw @"
Local configuration '$configPath' was not found.
Copy 'config.example.psd1' to 'config.psd1' and replace every angle-bracket placeholder.
"@
    }
    return Import-PowerShellDataFile -Path $configPath
}

function Assert-ConfigValues {
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string[]] $Names
    )

    foreach ($name in $Names) {
        if (-not $Config.ContainsKey($name)) {
            throw "Configuration value '$name' is missing from config.psd1."
        }

        $value = [string]$Config[$name]
        if (
            [string]::IsNullOrWhiteSpace($value) -or
            $value -match '<[^>]+>' -or
            $value -match '^(YOUR|REPLACE)[_-]'
        ) {
            throw "Configuration value '$name' still contains a placeholder or is empty."
        }
    }
}

function Assert-NativeCommand {
    param([Parameter(Mandatory)][string] $Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found."
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter()][string[]] $Arguments = @(),
        [switch] $Capture
    )

    if ($Capture) {
        $output = & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
        }
        return ($output -join [Environment]::NewLine).Trim()
    }

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Initialize-PortableWindowsSession {
    param([Parameter(Mandatory)][hashtable] $Config)

    Assert-ConfigValues -Config $Config -Names @(
        'SubscriptionId',
        'ResourceGroup',
        'ClusterName',
        'KubectlContext',
        'RegistryName',
        'RegistryLoginServer'
    )

    Assert-NativeCommand -Name az
    Assert-NativeCommand -Name kubectl

    Invoke-Native az @(
        'account', 'set',
        '--subscription', $Config.SubscriptionId
    )

    $actualSubscription = Invoke-Native az @(
        'account', 'show',
        '--query', 'id',
        '--output', 'tsv'
    ) -Capture

    if ($actualSubscription -ne $Config.SubscriptionId) {
        throw "Azure CLI is using subscription '$actualSubscription', not '$($Config.SubscriptionId)'."
    }

    Invoke-Native kubectl @(
        '--context', $Config.KubectlContext,
        'cluster-info'
    )
}

function Get-RuntimeDigest {
    param([Parameter(Mandatory)][hashtable] $Config)

    Assert-ConfigValues -Config $Config -Names @('RuntimeSource')
    $match = [regex]::Match(
        [string]$Config.RuntimeSource,
        '@(sha256:[0-9a-fA-F]{64})$'
    )
    if (-not $match.Success) {
        throw "RuntimeSource must be pinned as '<registry>/<repository>@sha256:<64-hex-digest>'."
    }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Get-RuntimeTag {
    param([Parameter(Mandatory)][hashtable] $Config)

    if (
        $Config.ContainsKey('RuntimeTag') -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.RuntimeTag)
    ) {
        Assert-ConfigValues -Config $Config -Names @('RuntimeTag')
        return [string]$Config.RuntimeTag
    }

    $digest = Get-RuntimeDigest -Config $Config
    return "source-$($digest.Substring(7, 12))"
}

function Get-RuntimeImage {
    param([Parameter(Mandatory)][hashtable] $Config)

    Assert-ConfigValues -Config $Config -Names @(
        'RegistryLoginServer',
        'RuntimeRepository'
    )
    $digest = Get-RuntimeDigest -Config $Config
    return "$($Config.RegistryLoginServer)/$($Config.RuntimeRepository)@$digest"
}

function Get-TransferImage {
    param([Parameter(Mandatory)][hashtable] $Config)

    Assert-ConfigValues -Config $Config -Names @(
        'RegistryLoginServer',
        'TransferRepository',
        'TransferTag'
    )
    return "$($Config.RegistryLoginServer)/$($Config.TransferRepository):$($Config.TransferTag)"
}

function Apply-ManifestTemplate {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][hashtable] $Replacements,
        [Parameter(Mandatory)][hashtable] $Config
    )

    $manifest = Get-Content -Raw -Path $Path
    foreach ($key in $Replacements.Keys) {
        $manifest = $manifest.Replace("__${key}__", [string]$Replacements[$key])
    }

    $remainingToken = [regex]::Match($manifest, '__[A-Z0-9_]+__')
    if ($remainingToken.Success) {
        throw "Manifest '$Path' still contains unresolved token '$($remainingToken.Value)'."
    }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $manifest |
            & kubectl --context $Config.KubectlContext apply -f -
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -lt 6) {
            Write-Warning "Applying '$Path' failed; retrying in 10 seconds (attempt $attempt of 6)."
            Start-Sleep -Seconds 10
        }
    }
    throw "Applying manifest '$Path' failed after 6 attempts."
}

function New-OrasCredential {
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $Namespace,
        [Parameter(Mandatory)][ValidateSet('pull', 'push')][string] $Access
    )

    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tokenName = "pw-$Access-$suffix"
    $scopeName = "pw-$Access-$suffix"
    Assert-ConfigValues -Config $Config -Names @(
        'RegistryName',
        'ArtifactRepository'
    )
    $actions = if ($Access -eq 'push') {
        @('content/read', 'content/write', 'metadata/read', 'metadata/write')
    }
    else {
        @('content/read', 'metadata/read')
    }

    $scopeArguments = @(
        'acr', 'scope-map', 'create',
        '--registry', $Config.RegistryName,
        '--name', $scopeName,
        '--repository', $Config.ArtifactRepository
    ) + $actions + @(
        '--description', "Temporary $Access access for portable Windows",
        '--output', 'none'
    )
    Invoke-Native az $scopeArguments

    try {
        Invoke-Native az @(
            'acr', 'token', 'create',
            '--registry', $Config.RegistryName,
            '--name', $tokenName,
            '--scope-map', $scopeName,
            '--no-passwords',
            '--output', 'none'
        )

        $password = Invoke-Native az @(
            'acr', 'token', 'credential', 'generate',
            '--registry', $Config.RegistryName,
            '--name', $tokenName,
            '--password1',
            '--expiration-in-days', '1',
            '--query', 'passwords[0].value',
            '--output', 'tsv'
        ) -Capture

        $secret = @{
            apiVersion = 'v1'
            kind = 'Secret'
            metadata = @{
                name = 'portable-windows-oras'
                namespace = $Namespace
            }
            type = 'Opaque'
            data = @{
                username = [Convert]::ToBase64String(
                    [Text.Encoding]::UTF8.GetBytes($tokenName)
                )
                password = [Convert]::ToBase64String(
                    [Text.Encoding]::UTF8.GetBytes($password)
                )
            }
        } | ConvertTo-Json -Depth 5

        $secret |
            & kubectl --context $Config.KubectlContext apply -f - |
            Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Creating the temporary ORAS Secret failed with exit code $LASTEXITCODE."
        }

        return @{
            TokenName = $tokenName
            ScopeName = $scopeName
            Namespace = $Namespace
        }
    }
    catch {
        & az acr token delete `
            --registry $Config.RegistryName `
            --name $tokenName `
            --yes `
            --output none 2>$null
        & az acr scope-map delete `
            --registry $Config.RegistryName `
            --name $scopeName `
            --yes `
            --output none 2>$null
        throw
    }
}

function Remove-OrasCredential {
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][hashtable] $Credential
    )

    & kubectl --context $Config.KubectlContext `
        --namespace $Credential.Namespace `
        delete secret portable-windows-oras `
        --ignore-not-found

    & az acr token delete `
        --registry $Config.RegistryName `
        --name $Credential.TokenName `
        --yes `
        --output none

    & az acr scope-map delete `
        --registry $Config.RegistryName `
        --name $Credential.ScopeName `
        --yes `
        --output none
}

function Wait-ForJob {
    param(
        [Parameter(Mandatory)][hashtable] $Config,
        [Parameter(Mandatory)][string] $Namespace,
        [Parameter(Mandatory)][string] $Name,
        [int] $TimeoutMinutes = 120
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $consecutiveApiErrors = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $job = Invoke-Native kubectl @(
                '--context', $Config.KubectlContext,
                '--namespace', $Namespace,
                'get', "job/$Name",
                '--output', 'json'
            ) -Capture | ConvertFrom-Json
            $consecutiveApiErrors = 0
        }
        catch {
            $consecutiveApiErrors++
            if ($consecutiveApiErrors -ge 6) {
                throw
            }
            Write-Warning "Unable to read Job status; retrying in 10 seconds. $($_.Exception.Message)"
            Start-Sleep -Seconds 10
            continue
        }

        $conditions = if (
            $job.status.PSObject.Properties.Name -contains 'conditions'
        ) {
            @($job.status.conditions)
        }
        else {
            @()
        }

        $complete = @(
            $conditions | Where-Object {
                $_.type -eq 'Complete' -and $_.status -eq 'True'
            }
        ).Count -gt 0
        if ($complete) {
            Invoke-Native kubectl @(
                '--context', $Config.KubectlContext,
                '--namespace', $Namespace,
                'logs', "job/$Name",
                '--all-containers'
            )
            return
        }

        $failed = @(
            $conditions | Where-Object {
                $_.type -eq 'Failed' -and $_.status -eq 'True'
            }
        ).Count -gt 0
        if ($failed) {
            & kubectl --context $Config.KubectlContext `
                --namespace $Namespace `
                describe "job/$Name"
            & kubectl --context $Config.KubectlContext `
                --namespace $Namespace `
                logs "job/$Name" `
                --all-containers
            throw "Job '$Namespace/$Name' failed."
        }

        Start-Sleep -Seconds 10
    }

    & kubectl --context $Config.KubectlContext `
        --namespace $Namespace `
        describe "job/$Name"
    & kubectl --context $Config.KubectlContext `
        --namespace $Namespace `
        logs "job/$Name" `
        --all-containers
    throw "Job '$Namespace/$Name' did not complete within $TimeoutMinutes minutes."
}
