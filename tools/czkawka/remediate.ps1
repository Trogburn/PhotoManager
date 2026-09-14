[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$DecisionPath,

    [Parameter()]
    [string]$QuarantineRoot = '.\reports\quarantine',

    [Parameter()]
    [string]$ScanRoot,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$TransactionManifestPath = '.\reports\quarantine\transactions.jsonl',

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [switch]$Undo,

    [Parameter()]
    [string[]]$UndoSourcePath,

    [Parameter()]
    [string]$UndoSourcePathFile,

    [Parameter()]
    [string]$ScanId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
}
. (Join-Path $PSScriptRoot 'common-hash.ps1')
. (Join-Path $PSScriptRoot 'common-scan-id.ps1')
. (Join-Path $PSScriptRoot 'common-config.ps1')

function Get-Value {
    param([object]$Value, [string]$Name)
    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) { return $null }
    return $Value.PSObject.Properties[$Name].Value
}

function Test-PathMatch {
    param([string]$PathValue, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($PathValue.StartsWith([string]$pattern, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-TimeMatch {
    param([datetime]$Actual, [object]$Expected)
    if ($null -eq $Expected) { return $true }
    $expectedDate = if ($Expected -is [datetime]) { ([datetime]$Expected).ToUniversalTime() } else { [datetime]::Parse([string]$Expected).ToUniversalTime() }
    return [math]::Abs(($Actual.ToUniversalTime() - $expectedDate).TotalSeconds) -le 1
}

function Get-ComparableHash {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text -match '^[0-9a-fA-F]{64}$') { return $text.ToLowerInvariant() }
    return $null
}

function Get-FileEvidence {
    param([System.IO.FileInfo]$File)
    $hash = Get-Sha256Hex -LiteralPath $File.FullName
    return [ordered]@{
        path = $File.FullName
        size = [long]$File.Length
        lastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
        sha256 = $hash
    }
}

function Get-RelativeDestination {
    param([string]$SourcePath, [string]$Root, [string]$Quarantine)
    $relative = $null
    if ($Root -and $SourcePath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $SourcePath.Substring($Root.Length).TrimStart('\', '/')
    }
    if ([string]::IsNullOrWhiteSpace($relative)) {
        $drive = ([IO.Path]::GetPathRoot($SourcePath) -replace '[:\\/]', '')
        $relative = Join-Path (Join-Path 'external' $drive) ([IO.Path]::GetFileName($SourcePath))
    }
    $destination = Join-Path $Quarantine $relative
    $parent = Split-Path -Path $destination -Parent
    if (Test-Path -LiteralPath $destination) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($destination)
        $extension = [IO.Path]::GetExtension($destination)
        $suffix = (Get-Sha256Hex -LiteralPath $SourcePath).Substring(0, 12)
        $destination = Join-Path $parent "$stem.quarantine-$suffix$extension"
        $counter = 1
        while (Test-Path -LiteralPath $destination) {
            $destination = Join-Path $parent "$stem.quarantine-$suffix-$counter$extension"
            $counter++
        }
    }
    return $destination
}

function Add-Transaction {
    param([object]$Entry)
    $parent = Split-Path -Path $TransactionManifestPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    ($Entry | ConvertTo-Json -Compress -Depth 10) | Add-Content -LiteralPath $TransactionManifestPath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $DecisionPath)) { throw "Decision file not found: $DecisionPath" }
$config = if (Test-Path -LiteralPath $ConfigPath) { Get-CzkawkaConfig -ConfigPath $ConfigPath } else { $null }
$protectedPaths = if ($null -ne $config) { @($config.scan.protectedPaths) } else { @() }
$excludedPaths = if ($null -ne $config) { @($config.scan.excludedPaths) } else { @() }
$decisions = @((Get-Content -LiteralPath $DecisionPath -Raw | ConvertFrom-Json) | Write-Output)

if ($Undo) {
    if (-not (Test-Path -LiteralPath $TransactionManifestPath)) { throw "Transaction manifest not found: $TransactionManifestPath" }
    $history = @(Get-Content -LiteralPath $TransactionManifestPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $resolvedScanId = $ScanId
    if ([string]::IsNullOrWhiteSpace($resolvedScanId) -and -not [string]::IsNullOrWhiteSpace($InputPath) -and (Test-Path -LiteralPath $InputPath)) {
        $classifiedForScope = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
        $resolvedScanId = Get-ResolvedScanId -Classified $classifiedForScope -ClassifiedPath $InputPath
    }
    $requestedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($UndoSourcePath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            $requestedPaths.Add([string]$path)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($UndoSourcePathFile)) {
        if (-not (Test-Path -LiteralPath $UndoSourcePathFile)) {
            throw "Undo path list not found: $UndoSourcePathFile"
        }
        foreach ($path in Get-Content -LiteralPath $UndoSourcePathFile) {
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $requestedPaths.Add($path.Trim())
            }
        }
    }
    if ($requestedPaths.Count -eq 0 -or -not [string]::IsNullOrWhiteSpace($resolvedScanId)) {
        $history = @(Select-TransactionHistoryForScan -History $history -ScanId $resolvedScanId -RequireScanId:($requestedPaths.Count -eq 0))
    }
    $undone = @{}
    foreach ($entry in @($history | Where-Object { $_.status -eq 'undone' })) {
        $undone["$($entry.source)|$($entry.destination)"] = $true
    }
    $entries = @($history | Where-Object {
        $_.status -eq 'moved' -and -not $undone.ContainsKey("$($_.source)|$($_.destination)")
    })
    $alreadyUndoneCount = @($history | Where-Object { $_.status -eq 'moved' -and $undone.ContainsKey("$($_.source)|$($_.destination)") }).Count
    if ($requestedPaths.Count -gt 0) {
        $requested = @{}
        foreach ($path in $requestedPaths) { $requested[[IO.Path]::GetFullPath($path)] = $true }
        $entries = @($entries | Where-Object { $requested.ContainsKey([IO.Path]::GetFullPath([string]$_.source)) })
    }
    if ($entries.Count -eq 0) {
        Write-Host "No active quarantine transaction(s) matched the undo request. Previously restored: $alreadyUndoneCount."
        return [pscustomobject]@{ undoneCount = 0; alreadyUndoneCount = $alreadyUndoneCount }
    }
    foreach ($entry in ($entries | Sort-Object transactionUtc -Descending)) {
        if (-not (Test-Path -LiteralPath $entry.destination)) { throw "Undo refused; quarantine file is missing: $($entry.destination)" }
        if (Test-Path -LiteralPath $entry.source) { throw "Undo refused; source already exists: $($entry.source)" }
        $current = Get-Item -LiteralPath $entry.destination -Force
        $currentHash = Get-Sha256Hex -LiteralPath $entry.destination
        if ($current.Length -ne [long]$entry.postMove.size -or -not (Test-TimeMatch $current.LastWriteTimeUtc $entry.postMove.lastWriteTimeUtc) -or
            $currentHash -ne $entry.postMove.sha256) { throw "Undo refused; quarantine file changed: $($entry.destination)" }
    }
    foreach ($entry in ($entries | Sort-Object transactionUtc -Descending)) {
        $sourceParent = Split-Path -Path $entry.source -Parent
        if (-not (Test-Path -LiteralPath $sourceParent)) { New-Item -Path $sourceParent -ItemType Directory -Force | Out-Null }
        Move-Item -LiteralPath $entry.destination -Destination $entry.source
        if (Test-Path -LiteralPath $entry.destination) {
            throw "Undo verification failed; quarantine path still exists: $($entry.destination)"
        }
        if (-not (Test-Path -LiteralPath $entry.source)) {
            throw "Undo verification failed; restored file is missing: $($entry.source)"
        }
        $restored = Get-Item -LiteralPath $entry.source -Force
        $restoredHash = Get-Sha256Hex -LiteralPath $entry.source
        $expected = $entry.preMove
        if ($null -eq $expected -or $restored.Length -ne [long]$expected.size -or $restoredHash -ne [string]$expected.sha256) {
            throw "Undo verification failed; restored file does not match pre-move evidence: $($entry.source)"
        }
        $entryScanId = if ($null -ne $entry.PSObject.Properties['scanId'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.scanId)) {
            [string]$entry.scanId
        } else {
            $resolvedScanId
        }
        Add-Transaction ([ordered]@{
            status = 'undone'
            source = $entry.source
            destination = $entry.destination
            transactionUtc = (Get-Date).ToUniversalTime().ToString('o')
            scanId = $entryScanId
            verificationPassed = $true
            restored = Get-FileEvidence -File $restored
        })
    }
    Write-Host "Undo completed for $($entries.Count) transaction(s). Previously restored entries skipped: $alreadyUndoneCount."
    return [pscustomobject]@{ undoneCount = $entries.Count; alreadyUndoneCount = $alreadyUndoneCount; verificationPassed = $true }
}

if ([string]::IsNullOrWhiteSpace($InputPath)) { throw '-InputPath is required unless -Undo is specified.' }
if (-not (Test-Path -LiteralPath $InputPath)) { throw "Classified input not found: $InputPath" }
$classified = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
if ($classified.schemaVersion -ne 1 -or $classified.source -ne 'classifier') { throw 'Input must be a schema version 1 classifier document.' }
$resolvedScanId = if (-not [string]::IsNullOrWhiteSpace($ScanId)) { $ScanId.Trim() } else { Get-ResolvedScanId -Classified $classified -ClassifiedPath $InputPath }
$quarantinePath = [IO.Path]::GetFullPath($QuarantineRoot)
$scanRootValue = if ($ScanRoot) { $ScanRoot } else { [string](Get-Value $classified 'scanRoot') }
$itemsByPath = @{}
foreach ($group in @($classified.groups)) {
    $keepPath = [string]$group.suggestedKeepPath
    foreach ($item in @($group.items)) {
        $itemsByPath[[string]$item.path] = $item
    }
    $groupDecision = @($decisions | Where-Object {
        (Get-Value $_ 'groupId') -eq $group.groupId -and
        [string]::IsNullOrWhiteSpace([string](Get-Value $_ 'path'))
    }) | Select-Object -Last 1
    if ($null -ne $groupDecision -and $groupDecision.action -eq 'quarantine-requested') {
        foreach ($item in @($group.items) | Where-Object { $_.path -ne $keepPath }) { $item | Add-Member -NotePropertyName requested -NotePropertyValue $true -Force }
    }
    elseif ($null -ne $groupDecision -and $groupDecision.action -eq 'keep') {
        $keepPath = [string](Get-Value $groupDecision 'keepPath')
        if ([string]::IsNullOrWhiteSpace($keepPath)) { throw "Keep decision for group '$($group.groupId)' has no keepPath." }
        foreach ($item in @($group.items) | Where-Object { $_.path -ne $keepPath }) { $item | Add-Member -NotePropertyName requested -NotePropertyValue $true -Force }
    }
}
foreach ($decision in $decisions | Where-Object { (Get-Value $_ 'action') -eq 'quarantine-requested' -and (Get-Value $_ 'path') }) {
    if ($itemsByPath.ContainsKey([string]$decision.path)) {
        $item = $itemsByPath[[string]$decision.path]
        $item | Add-Member -NotePropertyName requested -NotePropertyValue $true -Force
        $item | Add-Member -NotePropertyName requestedSha256 -NotePropertyValue (Get-Value $decision 'sha256') -Force
    }
}

$results = @()
foreach ($path in @($itemsByPath.Keys | Sort-Object)) {
    $item = $itemsByPath[$path]
    $itemProtected = [bool](Get-Value $item 'protected') -or [bool](Get-Value $item 'isReference')
    if (-not (Get-Value $item 'requested') -or $itemProtected -or (Test-PathMatch $path $protectedPaths) -or (Test-PathMatch $path $excludedPaths)) {
        $reason = if ($itemProtected -or (Test-PathMatch $path $protectedPaths)) { 'protected' } elseif (Test-PathMatch $path $excludedPaths) { 'excluded' } else { 'not-requested' }
        $results += [ordered]@{ source = $path; status = 'skipped'; reason = $reason }
        continue
    }
    if (-not (Test-Path -LiteralPath $path)) { $results += [ordered]@{ source = $path; status = 'failed'; reason = 'source-missing' }; continue }
    $source = Get-Item -LiteralPath $path -Force
    $expectedHash = Get-ComparableHash -Value (Get-Value $item 'requestedSha256')
    $sourceHash = $null
    if ($null -ne $expectedHash) {
        $sourceHash = Get-Sha256Hex -LiteralPath $path
    }
    if ($source.Length -ne [long](Get-Value $item 'size') -or -not (Test-TimeMatch $source.LastWriteTimeUtc (Get-Value $item 'modifiedTime')) -or
        ($null -ne $expectedHash -and $sourceHash -ne $expectedHash)) {
        $results += [ordered]@{ source = $path; status = 'refused'; reason = 'stale-file' }
        continue
    }
    $destination = Get-RelativeDestination -SourcePath $path -Root $scanRootValue -Quarantine $quarantinePath
    $beforeMove = Get-FileEvidence -File $source
    $entry = [ordered]@{
        source = $path
        destination = $destination
        action = 'quarantine'
        reason = 'explicit-review-request'
        reviewerAction = 'quarantine-requested'
        scanId = $resolvedScanId
        transactionUtc = (Get-Date).ToUniversalTime().ToString('o')
        status = if ($Apply) { 'moved' } else { 'dry-run' }
        preMove = $beforeMove
    }
    if ($Apply) {
        try {
            $destinationParent = Split-Path -Path $destination -Parent
            if (-not (Test-Path -LiteralPath $destinationParent)) {
                New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null
            }
            Move-Item -LiteralPath $path -Destination $destination -ErrorAction Stop
            $moved = Get-Item -LiteralPath $destination -Force
            $entry.postMove = Get-FileEvidence -File $moved
            Add-Transaction $entry
        }
        catch {
            $entry.status = 'failed'
            $entry.reason = $_.Exception.Message
            $entry.postMove = $null
            Add-Transaction $entry
        }
    }
    $results += $entry
}

[pscustomobject]@{
    dryRun = (-not $Apply)
    quarantineRoot = $quarantinePath
    moved = @($results | Where-Object status -eq 'moved').Count
    dryRunCount = @($results | Where-Object status -eq 'dry-run').Count
    skipped = @($results | Where-Object status -eq 'skipped').Count
    refused = @($results | Where-Object status -eq 'refused').Count
    failed = @($results | Where-Object status -eq 'failed').Count
    results = @($results)
}
