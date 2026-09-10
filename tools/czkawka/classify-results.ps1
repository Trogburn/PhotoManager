[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$OutputPath,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Normalized result file not found: $InputPath"
}
$document = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
if ($document.schemaVersion -ne 1) {
    throw "Unsupported normalized result schema version: $($document.schemaVersion)"
}

$config = if (Test-Path -LiteralPath $ConfigPath) { Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } else { $null }
$protectedPaths = if ($null -ne $config) { @($config.scan.protectedPaths) } else { @() }
$preferredDirectories = if ($null -ne $config) { @($config.scan.preferredDirectories) } else { @() }

function Test-PathMatch {
    param([string]$PathValue, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
        $normalizedPattern = $pattern.TrimEnd('\', '/')
        if ($PathValue.Equals($normalizedPattern, [StringComparison]::OrdinalIgnoreCase) -or
            $PathValue.StartsWith($normalizedPattern + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $PathValue.StartsWith($normalizedPattern + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-Value {
    param([object]$Value, [string]$Name)
    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) { return $null }
    return $Value.PSObject.Properties[$Name].Value
}

function Get-NameQuality {
    param([string]$PathValue)
    $name = [IO.Path]::GetFileNameWithoutExtension($PathValue)
    $score = 0
    if ($name -match '\d{4}[-_]\d{2}[-_]\d{2}') { $score += 2 }
    if ($name -notmatch '^(copy|img|image|dsc|pxl)[-_]?\d*$') { $score++ }
    if ($name.Length -ge 4) { $score++ }
    if ($name -match '\s*\(\d+\)$') { $score -= 3 }
    return $score
}

$itemsByPath = @{}
$evidenceByPath = @{}
$edges = @()
foreach ($group in @($document.groups)) {
    $paths = @()
    $groupEvidence = @()
    foreach ($entry in @($group.entries)) {
        $path = [string]$entry.path
        $paths += $path
        $entryEvidence = [ordered]@{
            sourceGroupId = [string]$group.groupId
            source = [string](Get-Value $group 'source')
            kind = [string](Get-Value $group 'kind')
            sourceScan = [string](Get-Value $entry 'sourceScan')
            groupId = [string](Get-Value $entry 'groupId')
            path = $path
            size = Get-Value $entry 'size'
            modifiedTime = Get-Value $entry 'modifiedTime'
            hash = Get-Value $entry 'hash'
            width = Get-Value $entry 'width'
            height = Get-Value $entry 'height'
            perceptualDifference = Get-Value $entry 'perceptualDifference'
            isReference = [bool](Get-Value $entry 'isReference')
            referenceState = [string](Get-Value $entry 'referenceState')
            warning = Get-Value $entry 'warning'
            accessState = Get-Value $entry 'accessState'
            error = Get-Value $entry 'error'
            isStale = [bool](Get-Value $entry 'isStale')
            staleReason = Get-Value $entry 'staleReason'
        }
        $groupEvidence += [pscustomobject]$entryEvidence
        if (-not $evidenceByPath.ContainsKey($path)) { $evidenceByPath[$path] = @() }
        $evidenceByPath[$path] += [pscustomobject]$entryEvidence
        if (-not $itemsByPath.ContainsKey($path)) {
            $itemsByPath[$path] = [ordered]@{
                path = $path
                size = [long](Get-Value $entry 'size')
                modifiedTime = Get-Value $entry 'modifiedTime'
                hash = Get-Value $entry 'hash'
                width = Get-Value $entry 'width'
                height = Get-Value $entry 'height'
                perceptualDifference = Get-Value $entry 'perceptualDifference'
                isReference = [bool](Get-Value $entry 'isReference')
                referenceState = [string](Get-Value $entry 'referenceState')
                warning = Get-Value $entry 'warning'
                accessState = [string](Get-Value $entry 'accessState')
                error = Get-Value $entry 'error'
                isStale = [bool](Get-Value $entry 'isStale')
                staleReason = Get-Value $entry 'staleReason'
            }
        }
        else {
            $item = $itemsByPath[$path]
            foreach ($property in @('size', 'modifiedTime', 'hash', 'width', 'height', 'perceptualDifference', 'referenceState', 'warning', 'accessState', 'error', 'staleReason')) {
                $current = $item[$property]
                $incoming = Get-Value $entry $property
                if (($null -eq $current -or [string]::IsNullOrWhiteSpace([string]$current)) -and $null -ne $incoming) {
                    $item[$property] = $incoming
                }
            }
            if ([bool](Get-Value $entry 'isReference')) { $item.isReference = $true }
            if ([bool](Get-Value $entry 'isStale')) { $item.isStale = $true }
        }
    }
    $edges += [ordered]@{
        sourceGroupId = [string]$group.groupId
        source = [string](Get-Value $group 'source')
        kind = [string](Get-Value $group 'kind')
        paths = @($paths | Sort-Object -Unique)
        entries = @($groupEvidence)
    }
}

$paths = @($itemsByPath.Keys | Sort-Object)
$indexByPath = @{}
for ($i = 0; $i -lt $paths.Count; $i++) { $indexByPath[$paths[$i]] = $i }
$adjacency = @{}
for ($i = 0; $i -lt $paths.Count; $i++) { $adjacency[$i] = @{} }
foreach ($edge in $edges) {
    $indexes = @($edge.paths | ForEach-Object { $indexByPath[$_] })
    foreach ($left in $indexes) {
        foreach ($right in $indexes) {
            if ($left -ne $right) { $adjacency[$left][$right] = $true }
        }
    }
}

$reviewGroups = @()
$visited = @{}
$componentNumber = 0
if ($paths.Count -gt 0) {
    foreach ($start in (0..($paths.Count - 1))) {
        if ($visited.ContainsKey($start)) { continue }
        $queue = New-Object 'System.Collections.Generic.Queue[int]'
        $queue.Enqueue($start)
        $visited[$start] = $true
        $indexes = @()
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $indexes += $current
            foreach ($neighbor in @($adjacency[$current].Keys | Sort-Object)) {
                if (-not $visited.ContainsKey([int]$neighbor)) {
                    $visited[[int]$neighbor] = $true
                    $queue.Enqueue([int]$neighbor)
                }
            }
        }

        $componentPaths = @($indexes | ForEach-Object { $paths[$_] } | Sort-Object)
        $componentItems = @($componentPaths | ForEach-Object { [pscustomobject]$itemsByPath[$_] })
        $componentEdges = @($edges | Where-Object { @($_.paths | Where-Object { $componentPaths -contains $_ }).Count -gt 0 })
        $hashes = @($componentItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.hash) } | ForEach-Object { [string]$_.hash.ToLowerInvariant() })
        $hasMatchingHash = @($hashes | Group-Object | Where-Object Count -gt 1).Count -gt 0
        $hasExact = (@($componentEdges | Where-Object { $_.kind -eq 'duplicate' }).Count -gt 0) -or $hasMatchingHash
        $differences = @($componentItems | Where-Object { $null -ne $_.perceptualDifference } | ForEach-Object { [double]$_.perceptualDifference })
        $minimumDifference = if ($differences.Count -gt 0) { ($differences | Measure-Object -Minimum).Minimum } else { $null }
        $areas = @($componentItems | Where-Object { [double]$_.width -gt 0 -and [double]$_.height -gt 0 } | ForEach-Object { [double]$_.width * [double]$_.height })
        $areaRatio = if ($areas.Count -gt 1) { [math]::Round(($areas | Measure-Object -Minimum).Minimum / ($areas | Measure-Object -Maximum).Maximum, 4) } else { $null }

        if ($hasExact) { $tier = 'Very high' }
        elseif ($null -ne $minimumDifference -and $minimumDifference -le 1 -and ($null -eq $areaRatio -or $areaRatio -ge 0.25)) { $tier = 'High' }
        elseif ($null -ne $minimumDifference -and $minimumDifference -le 8) { $tier = 'Medium' }
        else { $tier = 'Review carefully' }

        $labels = @()
        if ($hasExact) { $labels += 'exact duplicate' }
        if ($null -ne $areaRatio -and $areaRatio -lt 0.25) { $labels += 'likely thumbnail' }
        elseif ($null -ne $areaRatio -and $areaRatio -lt 0.9) { $labels += 'resized copy' }
        if (@($componentItems | Where-Object { (Get-NameQuality $_.path) -gt 2 }).Count -gt 0) { $labels += 'filename variant' }
        $directories = @($componentItems | ForEach-Object { Split-Path $_.path -Parent } | Sort-Object -Unique)
        if ($directories.Count -gt 1) { $labels += 'cross-folder match' }
        if (@($componentItems | Where-Object { $_.path -match '(?i)\\(downloads?|incoming)\\' }).Count -gt 0) { $labels += 'downloaded copy' }
        if ($labels.Count -eq 0) { $labels += 'downloaded copy' }

        $protected = @($componentItems | Where-Object { $_.isReference -or (Test-PathMatch $_.path $protectedPaths) })
        $candidates = @($componentItems | Sort-Object @{ Expression = { if (Test-PathMatch $_.path $preferredDirectories) { 0 } else { 1 } } }, @{ Expression = { if ($_.isReference) { 0 } else { 1 } } }, @{ Expression = { -[double]$_.width * [double]$_.height } }, @{ Expression = { -[long]$_.size } }, @{ Expression = { -(Get-NameQuality $_.path) } }, path)
        $suggested = $candidates | Select-Object -First 1
        $suggestedPath = [string]$suggested.path
        $reason = if ($suggested.isReference -or (Test-PathMatch $suggestedPath $protectedPaths)) { 'Reference/protected item is retained; recommendation is advisory.' } elseif (Test-PathMatch $suggestedPath $preferredDirectories) { 'Preferred directory and file quality signals.' } else { 'Dimension, size, and filename quality signals.' }

        $reviewGroups += [ordered]@{
            groupId = 'review-{0:D4}' -f ($componentNumber + 1)
            confidenceTier = $tier
            labels = @($labels | Sort-Object -Unique)
            explanation = [ordered]@{
                perceptualDifferenceMinimum = $minimumDifference
                dimensionAreaRatio = $areaRatio
                evidenceGroupIds = @($componentEdges | ForEach-Object sourceGroupId | Sort-Object -Unique)
                evidenceEdges = @($componentEdges)
            }
            suggestedKeepPath = $suggestedPath
            recommendationReason = $reason
            items = @($componentItems | Sort-Object @{ Expression = { if ($_.path -eq $suggestedPath) { 0 } else { 1 } } }, path | ForEach-Object {
                [ordered]@{
                    path = $_.path
                    size = $_.size
                    modifiedTime = $_.modifiedTime
                    hash = $_.hash
                    width = $_.width
                    height = $_.height
                    perceptualDifference = $_.perceptualDifference
                    isReference = $_.isReference
                    referenceState = $_.referenceState
                    warning = $_.warning
                    accessState = $_.accessState
                    error = $_.error
                    isStale = $_.isStale
                    staleReason = $_.staleReason
                    evidence = @($evidenceByPath[$_.path])
                    protected = ($_.isReference -or (Test-PathMatch $_.path $protectedPaths))
                    advisoryAction = if ($_.path -eq $suggestedPath) { 'keep' } elseif ($_.isReference -or (Test-PathMatch $_.path $protectedPaths)) { 'protect' } else { 'review' }
                }
            })
        }
        $componentNumber++
    }
}

if (-not $OutputPath) { $OutputPath = [IO.Path]::ChangeExtension($InputPath, '.classified.json') }
$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) { New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null }
$output = [ordered]@{
    schemaVersion = 1
    source = 'classifier'
    inputPath = [IO.Path]::GetFullPath($InputPath)
    groupCount = $reviewGroups.Count
    groups = @($reviewGroups)
}
$output | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8

[pscustomobject]@{ outputPath = (Resolve-Path -LiteralPath $OutputPath).Path; groupCount = $reviewGroups.Count }
