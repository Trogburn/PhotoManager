[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixture = Join-Path $PSScriptRoot 'fixtures\dup-group.json'
$output = Join-Path ([IO.Path]::GetTempPath()) "dup-group.normalized.$([guid]::NewGuid().ToString('N')).json"

try {
    & (Join-Path $PSScriptRoot '..\parse-results.ps1') -InputPath $fixture -OutputPath $output | Out-Null

    $data = Get-Content -Path $output -Raw | ConvertFrom-Json
    if ($data.groupCount -ne 1) {
        throw "Expected 1 group, got $($data.groupCount)"
    }

    if ($data.groups[0].entries.Count -ne 2) {
        throw "Expected 2 entries, got $($data.groups[0].entries.Count)"
    }

    if ($data.schemaVersion -ne 1) {
        throw "Expected schemaVersion 1, got $($data.schemaVersion)"
    }

    Write-Host 'Phase 2 parser smoke test passed.'
}
finally {
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    }
}
