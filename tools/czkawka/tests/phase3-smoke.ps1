[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "qnap-phase3-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $root -ItemType Directory -Force | Out-Null
try {
    $file = Join-Path $root '2024-02-03_camera.txt'
    'fixture' | Set-Content -Path $file -Encoding UTF8
    $before = Get-Item -LiteralPath $file -Force
    $beforeLastWrite = $before.LastWriteTimeUtc.ToString('o')
    $reportPath = Join-Path $root 'review.json'

    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $file -OutputPath $reportPath | Out-Null

    $report = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
    $item = @($report.items)[0]
    if (-not $report.dryRun -or $item.status -ne 'Proposed') {
        throw 'Filename fixture did not produce a dry-run proposal.'
    }
    if ($item.source -ne 'filename' -or ([datetime]$item.proposedCaptureTimeUtc).Date -ne [datetime]'2024-02-03') {
        throw 'Filename evidence was not normalized as expected.'
    }

    $after = Get-Item -LiteralPath $file -Force
    if ($after.LastWriteTimeUtc.ToString('o') -ne $beforeLastWrite) {
        throw 'Dry-run changed the file timestamp.'
    }

    $manifestPath = Join-Path $root 'undo.jsonl'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $file -OutputPath (Join-Path $root 'apply.json') -Apply -ApprovePath $file -UndoManifestPath $manifestPath | Out-Null
    $applied = Get-Item -LiteralPath $file -Force
    if ($applied.LastWriteTimeUtc.ToString('o') -ne $beforeLastWrite) {
        throw 'CreationTimeOnly policy changed LastWriteTime.'
    }
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw 'Approved change did not create an undo manifest.'
    }

    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Undo -UndoManifestPath $manifestPath | Out-Null
    $restored = Get-Item -LiteralPath $file -Force
    if ($restored.LastWriteTimeUtc.ToString('o') -ne $beforeLastWrite) {
        throw 'Undo did not restore LastWriteTime.'
    }

    Write-Host 'Phase 3 dry-run smoke test passed.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
