# Load committed config.json and overlay a sibling config.local.json when present.
# The local file is gitignored and must never be required for tests or packaging.

function Merge-CzkawkaConfigObject {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Source
    )

    foreach ($property in $Source.PSObject.Properties) {
        $incoming = $property.Value
        $existing = $Target.PSObject.Properties[$property.Name]
        if ($null -ne $existing -and $existing.Value -is [PSCustomObject] -and $incoming -is [PSCustomObject]) {
            Merge-CzkawkaConfigObject -Target $existing.Value -Source $incoming
            continue
        }

        $Target | Add-Member -NotePropertyName $property.Name -NotePropertyValue $incoming -Force
    }

    return $Target
}

function Get-CzkawkaConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $localPath = Join-Path (Split-Path -Parent $ConfigPath) 'config.local.json'
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
        [void](Merge-CzkawkaConfigObject -Target $config -Source $local)
    }

    return $config
}
