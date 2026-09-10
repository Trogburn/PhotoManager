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
    [switch]$ExportOnly,

    [Parameter()]
    [switch]$AllowLocalRoot
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
    $scanResult = & (Join-Path $PSScriptRoot 'scan.ps1') -ConfigPath $configFullPath -ScanRoot $effectiveRoot -Fresh:$Fresh -AllowLocalRoot:$AllowLocalRoot
    $scanDirectoryPath = [string]$scanResult.reportDir
    if ([string]::IsNullOrWhiteSpace($scanDirectoryPath) -or -not (Test-Path -LiteralPath $scanDirectoryPath)) {
        throw "Scan completed but no report directory was found under $reportRoot."
    }

    $combinedPath = Join-Path $scanDirectoryPath 'normalized\combined.normalized.json'
    $null = & (Join-Path $PSScriptRoot 'parse-results.ps1') -ScanReportDir $scanDirectoryPath -OutputPath $combinedPath
    $classifiedPath = Join-Path $scanDirectoryPath 'classified.json'
    & (Join-Path $PSScriptRoot 'classify-results.ps1') -InputPath $combinedPath -OutputPath $classifiedPath -ConfigPath $configFullPath | Out-Null

    $dateReviewPath = $null
    if ($IncludeDateReview) {
        $dateReviewPath = Join-Path $scanDirectoryPath 'date-review.json'
        & (Join-Path $PSScriptRoot 'repair-dates.ps1') -Path $effectiveRoot -Recurse -OutputPath $dateReviewPath | Out-Null
    }

    $htmlPath = Join-Path $scanDirectoryPath 'review.html'
    $jsonPath = Join-Path $scanDirectoryPath 'review.json'
    $decisionPath = Join-Path $scanDirectoryPath 'decisions.json'
    $reviewParams = @{
        InputPath = $classifiedPath
        DecisionPath = $decisionPath
        HtmlReportPath = $htmlPath
        JsonReportPath = $jsonPath
        ExportOnly = $ExportOnly.IsPresent
    }
    if ($dateReviewPath) { $reviewParams.DateReviewPath = $dateReviewPath }
    & (Join-Path $PSScriptRoot 'review.ps1') @reviewParams | Out-Null

    [pscustomobject]@{
        scanDirectory = $scanDirectoryPath
        classifiedPath = $classifiedPath
        decisionPath = $decisionPath
        htmlReportPath = $htmlPath
        jsonReportPath = $jsonPath
        dateReviewPath = $dateReviewPath
        exportOnly = $ExportOnly.IsPresent
        allowLocalRoot = $AllowLocalRoot.IsPresent
    }
}
finally {
    Pop-Location
}
