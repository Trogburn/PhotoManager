[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common-config.ps1')

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "qnap-local-config-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $committed = Join-Path $tempRoot 'config.json'
    @{
        scan = @{
            uncRoot = '\\YOUR-SERVER\YOUR-SHARE\Photos'
            quarantineRoot = '.\reports\quarantine'
            protectedPaths = @('\\YOUR-SERVER\YOUR-SHARE\Reference')
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $committed -Encoding UTF8

    $withoutLocal = Get-CzkawkaConfig -ConfigPath $committed
    if ($withoutLocal.scan.uncRoot -ne '\\YOUR-SERVER\YOUR-SHARE\Photos') {
        throw 'Committed placeholders must remain when config.local.json is absent.'
    }

    @{
        scan = @{
            uncRoot = '\\NAS\DisposableLabShare\WpfAcceptance\Input'
            quarantineRoot = '\\NAS\DisposableLabShare\WpfAcceptance\Quarantine'
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $tempRoot 'config.local.json') -Encoding UTF8

    $merged = Get-CzkawkaConfig -ConfigPath $committed
    if ($merged.scan.uncRoot -ne '\\NAS\DisposableLabShare\WpfAcceptance\Input') {
        throw 'config.local.json must overlay scan.uncRoot.'
    }
    if ($merged.scan.quarantineRoot -ne '\\NAS\DisposableLabShare\WpfAcceptance\Quarantine') {
        throw 'config.local.json must overlay scan.quarantineRoot.'
    }
    if ($merged.scan.protectedPaths[0] -ne '\\YOUR-SERVER\YOUR-SHARE\Reference') {
        throw 'Unspecified committed scan fields must remain after overlay.'
    }

    Write-Host 'Local config overlay tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
