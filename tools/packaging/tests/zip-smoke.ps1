[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\Test-PackagedZip.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$packagingRoot = Join-Path $repoRoot 'tools\packaging'
$toolsSource = Join-Path $repoRoot 'tools\czkawka'
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "photo-zip-smoke-$([guid]::NewGuid().ToString('N'))"
$zipPath = "$stage.zip"

New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $toolsDestination = Join-Path $stage 'tools\czkawka'
    New-Item -ItemType Directory -Path $toolsDestination -Force | Out-Null
    Get-ChildItem -LiteralPath $toolsSource -Force |
        Where-Object { $_.Name -notin @('tests', 'bin', 'temp') -and $_.Name -notlike '*.local.json' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $toolsDestination $_.Name) -Recurse -Force
        }

    Copy-Item -LiteralPath (Join-Path $packagingRoot 'Install-PhotoManager.ps1') -Destination $stage -Force
    Copy-Item -LiteralPath (Join-Path $packagingRoot 'Install.bat') -Destination $stage -Force
    Copy-Item -LiteralPath (Join-Path $packagingRoot 'README.txt') -Destination $stage -Force
    Copy-Item -LiteralPath (Join-Path $packagingRoot 'GETTING_STARTED.md') -Destination $stage -Force

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Fastest

    Test-PackagedZipEntries -ZipPath $zipPath -Required @(
        'tools\czkawka\scan.ps1',
        'tools\czkawka\repair-dates.ps1',
        'tools\czkawka\repair-orientation.ps1',
        'tools\czkawka\remediate.ps1',
        'Install.bat',
        'Install-PhotoManager.ps1',
        'README.txt',
        'GETTING_STARTED.md'
    )

    Write-Host "Zip smoke passed: repair-orientation.ps1 ships in $zipPath"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
}
