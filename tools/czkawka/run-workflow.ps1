[CmdletBinding()]
param(
    [Parameter()]
    [string]$ScanRoot,

    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [switch]$Fresh,

    [Parameter()]
    [switch]$IncludeDateReview,

    [Parameter()]
    [switch]$ExportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$configFullPath = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $configFullPath)) { throw "Configuration file not found: $configFullPath" }
$config = Get-Content -LiteralPath $configFullPath -Raw | ConvertFrom-Json
$effectiveRoot = if ($ScanRoot) { $ScanRoot } else { [string]$config.scan.uncRoot }
if ([string]::IsNullOrWhiteSpace($effectiveRoot) -or $effectiveRoot -like '*YOUR-SERVER*') {
    throw 'Set scan.uncRoot in tools/czkawka/config.json or provide -ScanRoot with the real UNC path.'
}

Push-Location $repositoryRoot
try {
    $reportRoot = [IO.Path]::GetFullPath([string]$config.scan.localReportRoot)
    & (Join-Path $PSScriptRoot 'scan.ps1') -ConfigPath $configFullPath -ScanRoot $effectiveRoot -Fresh:$Fresh
    $scanDirectory = @(Get-ChildItem -LiteralPath $reportRoot -Directory -Filter 'scan-*' | Sort-Object CreationTime -Descending | Select-Object -First 1)[0]
    if ($null -eq $scanDirectory) { throw "Scan completed but no report directory was found under $reportRoot." }

    $normalizedDir = Join-Path $scanDirectory.FullName 'normalized'
    New-Item -Path $normalizedDir -ItemType Directory -Force | Out-Null
    $dupRaw = Join-Path $scanDirectory.FullName 'raw\dup.json'
    $imageRaw = Join-Path $scanDirectory.FullName 'raw\image.json'
    $dupNormalized = Join-Path $normalizedDir 'dup.normalized.json'
    $imageNormalized = Join-Path $normalizedDir 'image.normalized.json'
    & (Join-Path $PSScriptRoot 'parse-results.ps1') -InputPath $dupRaw -OutputPath $dupNormalized -Mode auto -SourceScan 'dup' -CzkawkaVersion $config.czkawka.version -ScanRoot $effectiveRoot -ScanTimestampUtc $scanDirectory.CreationTimeUtc.ToString('o') -RawArtifactPath $dupRaw | Out-Null
    & (Join-Path $PSScriptRoot 'parse-results.ps1') -InputPath $imageRaw -OutputPath $imageNormalized -Mode auto -SourceScan 'image' -CzkawkaVersion $config.czkawka.version -ScanRoot $effectiveRoot -ScanTimestampUtc $scanDirectory.CreationTimeUtc.ToString('o') -RawArtifactPath $imageRaw | Out-Null

    $dupDocument = Get-Content -LiteralPath $dupNormalized -Raw | ConvertFrom-Json
    $imageDocument = Get-Content -LiteralPath $imageNormalized -Raw | ConvertFrom-Json
    $combined = [ordered]@{
        schemaVersion = 1
        source = 'czkawka'
        inputPath = $scanDirectory.FullName
        scanRoot = $effectiveRoot
        czkawkaVersion = $config.czkawka.version
        groups = @(@($dupDocument.groups) + @($imageDocument.groups))
    }
    $combinedPath = Join-Path $normalizedDir 'combined.normalized.json'
    $combined | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $combinedPath -Encoding UTF8
    $classifiedPath = Join-Path $scanDirectory.FullName 'classified.json'
    & (Join-Path $PSScriptRoot 'classify-results.ps1') -InputPath $combinedPath -OutputPath $classifiedPath -ConfigPath $configFullPath | Out-Null

    $dateReviewPath = $null
    if ($IncludeDateReview) {
        $dateReviewPath = Join-Path $scanDirectory.FullName 'date-review.json'
        & (Join-Path $PSScriptRoot 'repair-dates.ps1') -Path $effectiveRoot -Recurse -OutputPath $dateReviewPath | Out-Null
    }

    $htmlPath = Join-Path $scanDirectory.FullName 'review.html'
    $decisionPath = Join-Path $scanDirectory.FullName 'decisions.json'
    $reviewArgs = @('-InputPath', $classifiedPath, '-DecisionPath', $decisionPath, '-HtmlReportPath', $htmlPath)
    if ($dateReviewPath) { $reviewArgs += @('-DateReviewPath', $dateReviewPath) }
    if ($ExportOnly) { $reviewArgs += '-ExportOnly' }
    & (Join-Path $PSScriptRoot 'review.ps1') @reviewArgs

    [pscustomobject]@{
        scanDirectory = $scanDirectory.FullName
        classifiedPath = $classifiedPath
        decisionPath = $decisionPath
        htmlReportPath = $htmlPath
        dateReviewPath = $dateReviewPath
        exportOnly = $ExportOnly.IsPresent
    }
}
finally {
    Pop-Location
}
