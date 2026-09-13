[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputPath,
    [Parameter(Mandatory)] [string]$DecisionPath,
    [Parameter(Mandatory)] [string]$TransactionManifestPath,
    [Parameter(Mandatory)] [string]$ScanRoot,
    [Parameter(Mandatory)] [string]$QuarantineRoot,
    [string]$ConfigPath,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [switch]$AllowLocalRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
}
. (Join-Path $PSScriptRoot 'common-hash.ps1')
. (Join-Path $PSScriptRoot 'common-scan-id.ps1')

function Get-Value { param([object]$Object, [string]$Name) if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }; $Object.PSObject.Properties[$Name].Value }
function Get-JsonArray { param([string]$Path) return @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) | Write-Output) }
function Test-PathMatch { param([string]$PathValue, [string[]]$Roots) foreach ($root in $Roots) { if ($PathValue.StartsWith([string]$root, [StringComparison]::OrdinalIgnoreCase)) { return $true } }; $false }

foreach ($path in @($InputPath, $DecisionPath, $TransactionManifestPath, $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input not found: $path" }
}
if (-not (Test-Path -LiteralPath $ScanRoot)) { throw "Scan root not found: $ScanRoot" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$classified = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
if ($classified.schemaVersion -ne 1 -or $classified.source -ne 'classifier') { throw 'InputPath must be a schema version 1 classifier document.' }
$decisions = Get-JsonArray $DecisionPath
$resolvedScanId = Get-ResolvedScanId -Classified $classified -ClassifiedPath $InputPath
$history = @(
    Select-TransactionHistoryForScan `
        -History @(Get-Content -LiteralPath $TransactionManifestPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) `
        -ScanId $resolvedScanId
)
$latestBySource = @{}
foreach ($entry in $history) {
    $latestBySource[[string]$entry.source] = $entry
}
$transactions = @($latestBySource.Values | Where-Object { $_.status -eq 'moved' })
$undoneSources = @{}
foreach ($entry in @($latestBySource.Values | Where-Object { $_.status -eq 'undone' })) {
    $undoneSources[[string]$entry.source] = $true
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$expected = @{}
$keepers = @{}
$deferred = @{}
foreach ($group in @($classified.groups)) {
    $groupDecision = @($decisions | Where-Object {
        (Get-Value $_ 'groupId') -eq $group.groupId -and
        [string]::IsNullOrWhiteSpace([string](Get-Value $_ 'path'))
    } | Select-Object -Last 1)
    if ($groupDecision.Count -eq 1) {
        if ($groupDecision[0].action -eq 'keep') {
            $keepers[[string]$groupDecision[0].keepPath] = $true
            foreach ($item in @($group.items) | Where-Object path -ne $groupDecision[0].keepPath) { $expected[[string]$item.path] = $true }
        } elseif ($groupDecision[0].action -eq 'quarantine-requested') {
            foreach ($item in @($group.items) | Where-Object path -ne $group.suggestedKeepPath) { $expected[[string]$item.path] = $true }
        } elseif ($groupDecision[0].action -eq 'defer') {
            foreach ($item in @($group.items)) { $deferred[[string]$item.path] = $true }
        }
    }
}
foreach ($decision in @($decisions | Where-Object {
    (Get-Value $_ 'action') -eq 'quarantine-requested' -and
    -not [string]::IsNullOrWhiteSpace([string](Get-Value $_ 'path'))
})) { $expected[[string](Get-Value $decision 'path')] = $true }

foreach ($path in @($expected.Keys)) {
    if ($undoneSources.ContainsKey($path)) {
        $expected.Remove($path)
    }
}

$failures = New-Object System.Collections.Generic.List[string]
$movedSources = @{}
foreach ($entry in $transactions) {
    $movedSources[[string]$entry.source] = $true
    if (-not $expected.ContainsKey([string]$entry.source)) { $failures.Add("Unauthorized transaction: $($entry.source)") }
    if (Test-Path -LiteralPath $entry.source) { $failures.Add("Moved source still exists: $($entry.source)") }
    if (-not (Test-Path -LiteralPath $entry.destination)) { $failures.Add("Quarantine destination missing: $($entry.destination)"); continue }
    $file = Get-Item -LiteralPath $entry.destination -Force
    $hash = Get-Sha256Hex -LiteralPath $entry.destination
    if ($file.Length -ne [long]$entry.postMove.size -or $hash -ne $entry.postMove.sha256) { $failures.Add("Quarantine evidence mismatch: $($entry.destination)") }
    if (Test-PathMatch $entry.source @($config.scan.protectedPaths) -or Test-PathMatch $entry.source @($config.scan.excludedPaths)) { $failures.Add("Protected/excluded file moved: $($entry.source)") }
}
foreach ($path in $expected.Keys) { if (-not $movedSources.ContainsKey($path)) { $failures.Add("Expected candidate was not moved: $path") } }
foreach ($path in $keepers.Keys) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Keeper missing: $path") }; if ($movedSources.ContainsKey($path)) { $failures.Add("Keeper moved: $path") } }
foreach ($path in $deferred.Keys) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Deferred file missing: $path") }; if ($movedSources.ContainsKey($path)) { $failures.Add("Deferred file moved: $path") } }
foreach ($path in $undoneSources.Keys) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Restored file is missing: $path")
        continue
    }
    $moved = @($history | Where-Object { $_.status -eq 'moved' -and [string]$_.source -eq $path }) | Select-Object -Last 1
    if ($null -ne $moved -and $null -ne $moved.preMove) {
        $file = Get-Item -LiteralPath $path -Force
        $hash = Get-Sha256Hex -LiteralPath $path
        if ($file.Length -ne [long]$moved.preMove.size -or $hash -ne [string]$moved.preMove.sha256) {
            $failures.Add("Restored file evidence mismatch: $path")
        }
    }
}

$post = & (Join-Path $PSScriptRoot 'run-workflow.ps1') -ScanRoot $ScanRoot -ConfigPath $ConfigPath -Fresh -ExportOnly -AllowLocalRoot:$AllowLocalRoot
$postClassified = Get-Content -LiteralPath $post.classifiedPath -Raw | ConvertFrom-Json
$report = [ordered]@{
    schemaVersion = 1; verifiedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); passed = ($failures.Count -eq 0)
    scanId = $resolvedScanId
    scanRoot = $ScanRoot; quarantineRoot = $QuarantineRoot; expectedMoveCount = $expected.Count; transactionCount = $transactions.Count
    undoneCount = $undoneSources.Count
    keeperCount = $keepers.Count; deferredFileCount = $deferred.Count; postScanDirectory = $post.scanDirectory; postScanGroupCount = @($postClassified.groups).Count
    failures = @($failures)
}
$jsonPath = Join-Path $OutputDirectory 'verification.json'
$htmlPath = Join-Path $OutputDirectory 'verification.html'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$failureHtml = if ($failures.Count) { '<ul>' + (($failures | ForEach-Object { '<li>' + [Net.WebUtility]::HtmlEncode($_) + '</li>' }) -join '') + '</ul>' } else { '<p>All checks passed.</p>' }
@("<!doctype html><meta charset='utf-8'><title>Remediation verification</title><h1>Remediation verification</h1><p>Passed: $($report.passed)</p><ul><li>Expected moves: $($report.expectedMoveCount)</li><li>Verified transactions: $($report.transactionCount)</li><li>Keepers retained: $($report.keeperCount)</li><li>Deferred files retained: $($report.deferredFileCount)</li><li>Post-scan groups: $($report.postScanGroupCount)</li></ul>$failureHtml<p>Post-scan: $([Net.WebUtility]::HtmlEncode($report.postScanDirectory))</p>") | Set-Content -LiteralPath $htmlPath -Encoding UTF8
if ($failures.Count) { throw "Verification failed with $($failures.Count) issue(s). See $jsonPath" }
[pscustomobject]@{ passed = $true; jsonPath = $jsonPath; htmlPath = $htmlPath; postScanDirectory = $post.scanDirectory; postScanGroupCount = $report.postScanGroupCount }
