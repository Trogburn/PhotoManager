[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$toolRoot = Join-Path $repoRoot 'tools\czkawka'
$workflow = Join-Path $toolRoot 'run-workflow.ps1'
$configPath = Join-Path $toolRoot 'config.json'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "photo-phase7-$([guid]::NewGuid().ToString('N'))"
$fixtureRoot = Join-Path $tempRoot 'fixture'
$reportRoot = Join-Path $tempRoot 'reports'

function Test-ScriptSyntax {
    param([string]$Path)

    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "PowerShell syntax check failed for $Path : $($parseErrors[0].ToString())"
    }
}

try {
    Test-ScriptSyntax -Path $workflow
    $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    $guide = Get-Content -LiteralPath (Join-Path $repoRoot 'USER_GUIDE.md') -Raw
    foreach ($requiredText in @(
        'SHA256',
        'third-party',
        'Task Scheduler',
        'scan/report',
        'cannot quarantine',
        'run-all-tests.ps1'
    )) {
        if ($readme -notmatch [regex]::Escape($requiredText) -and $guide -notmatch [regex]::Escape($requiredText)) {
            throw "Phase 7 documentation is missing required guidance: $requiredText"
        }
    }
    if ($guide -notmatch '(?is)Task Scheduler.{0,1000}cannot quarantine') {
        throw 'Task Scheduler guidance does not clearly prohibit quarantine.'
    }

    New-Item -Path $fixtureRoot -ItemType Directory -Force | Out-Null
    'phase7-safe-workflow' | Set-Content -LiteralPath (Join-Path $fixtureRoot 'one.jpg') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'one.jpg') -Destination (Join-Path $fixtureRoot 'two.jpg')
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config.scan.localReportRoot = $reportRoot
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $tempRoot 'config.json') -Encoding UTF8

    $result = & $workflow -ConfigPath (Join-Path $tempRoot 'config.json') -ScanRoot $fixtureRoot -AllowLocalRoot -ExportOnly
    if (-not $result -or -not (Test-Path -LiteralPath ([string]$result.classifiedPath))) {
        throw 'Safe end-to-end workflow did not produce classified output.'
    }
    $scanDirectory = [string]$result.scanDirectory
    foreach ($artifact in @(
        'raw\dup.json',
        'raw\image.json',
        'normalized\combined.normalized.json',
        'classified.json',
        'review.html',
        'review.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $scanDirectory $artifact))) {
            throw "Safe end-to-end workflow is missing artifact: $artifact"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $scanDirectory 'quarantine')) {
        throw 'Safe end-to-end workflow unexpectedly created a quarantine directory.'
    }
    Write-Host 'Phase 7 operational polish tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
