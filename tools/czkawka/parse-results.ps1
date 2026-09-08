[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter()]
    [string]$OutputPath,

    [ValidateSet('auto', 'grouped', 'flat')]
    [string]$Mode = 'auto',

    [string]$SourceScan = 'raw-czkawka',

    [string]$CzkawkaVersion,

    [string]$ScanRoot,

    [string]$ScanTimestampUtc,

    [string]$RawArtifactPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $InputPath)) {
    throw "Input result file not found: $InputPath"
}

$rawJson = Get-Content -Path $InputPath -Raw
if ([string]::IsNullOrWhiteSpace($rawJson)) {
    throw "Input result file is empty: $InputPath"
}

try {
    $parsed = $rawJson | ConvertFrom-Json
}
catch {
    throw ("Malformed JSON in {0}: {1}" -f $InputPath, $_.Exception.Message)
}

function Test-Property {
    param(
        [object]$Value,
        [string]$Name
    )

    return $null -ne $Value -and $Value.PSObject.Properties.Name -contains $Name
}

$items = @($parsed)
if ($Mode -eq 'auto') {
    if ($items.Count -eq 0) {
        $Mode = 'grouped'
    }
    elseif ((Test-Property -Value $items[0] -Name 'groupId') -or (Test-Property -Value $items[0] -Name 'entries')) {
        $Mode = 'grouped'
    }
    elseif ((Test-Property -Value $items[0] -Name 'path') -or (Test-Property -Value $items[0] -Name 'name')) {
        $Mode = 'flat'
    }
    else {
        throw "Unsupported JSON result shape in $InputPath. Expected an array of groups or file entries."
    }
}

function New-NormalizedEntry {
    param(
        [object]$Entry,
        [string]$SourceScan,
        [string]$GroupId
    )

    $pathValue = if (Test-Property -Value $Entry -Name 'path') { [string]$Entry.path } elseif (Test-Property -Value $Entry -Name 'name') { [string]$Entry.name } else { '' }
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        throw "Result entry is missing a path in $InputPath."
    }

    $sizeValue = if (Test-Property -Value $Entry -Name 'size') { [long]$Entry.size } else { 0 }
    $modifiedValue = if (Test-Property -Value $Entry -Name 'modifiedTime') { $Entry.modifiedTime } elseif (Test-Property -Value $Entry -Name 'mtime') { $Entry.mtime } else { $null }
    $hashValue = if (Test-Property -Value $Entry -Name 'hash') { [string]$Entry.hash } else { $null }
    $widthValue = if (Test-Property -Value $Entry -Name 'width') { [int]$Entry.width } else { $null }
    $heightValue = if (Test-Property -Value $Entry -Name 'height') { [int]$Entry.height } else { $null }
    $differenceValue = if (Test-Property -Value $Entry -Name 'difference') { [double]$Entry.difference } elseif (Test-Property -Value $Entry -Name 'perceptualDifference') { [double]$Entry.perceptualDifference } else { $null }

    return [ordered]@{
        path = $pathValue
        size = $sizeValue
        modifiedTime = $modifiedValue
        hash = $hashValue
        width = $widthValue
        height = $heightValue
        perceptualDifference = $differenceValue
        sourceScan = $SourceScan
        groupId = $GroupId
        isReference = if ($Entry.PSObject.Properties.Name -contains 'isReference') { [bool]$Entry.isReference } else { $false }
        referenceState = if ($Entry.PSObject.Properties.Name -contains 'referenceState') { [string]$Entry.referenceState } else { 'not-set' }
    }
}

$normalizedGroups = @()

switch ($Mode) {
    'grouped' {
        $groupIndex = 0
        foreach ($group in $items) {
            if (-not (Test-Property -Value $group -Name 'entries')) {
                throw "Grouped result at index $groupIndex is missing an entries array in $InputPath."
            }

            $groupId = if (Test-Property -Value $group -Name 'groupId') { [string]$group.groupId } else { "group-$groupIndex" }
            $entries = @()
            foreach ($entry in @($group.entries)) {
                if ($null -ne $entry) {
                    $entries += New-NormalizedEntry -Entry $entry -SourceScan $SourceScan -GroupId $groupId
                }
            }

            $normalizedGroups += [ordered]@{
                schemaVersion = 1
                source = 'czkawka'
                groupId = $groupId
                kind = if (Test-Property -Value $group -Name 'kind') { [string]$group.kind } else { 'unknown' }
                isReference = if (Test-Property -Value $group -Name 'isReference') { [bool]$group.isReference } else { $false }
                entries = $entries
            }
            $groupIndex++
        }
    }
    'flat' {
        $itemIndex = 0
        foreach ($item in $items) {
            $groupId = if (Test-Property -Value $item -Name 'groupId') { [string]$item.groupId } else { "group-$itemIndex" }
            $normalizedGroups += [ordered]@{
                schemaVersion = 1
                source = 'czkawka'
                groupId = $groupId
                kind = 'flat'
                isReference = if (Test-Property -Value $item -Name 'isReference') { [bool]$item.isReference } else { $false }
                entries = @(New-NormalizedEntry -Entry $item -SourceScan $SourceScan -GroupId $groupId)
            }
            $itemIndex++
        }
    }
    default {
        throw "Unsupported parse mode: $Mode"
    }
}

$normalizedDoc = [ordered]@{
    schemaVersion = 1
    source = 'czkawka'
    inputPath = $InputPath
    rawArtifactPath = if ($RawArtifactPath) { $RawArtifactPath } else { $InputPath }
    sourceScan = $SourceScan
    czkawkaVersion = $CzkawkaVersion
    scanRoot = $ScanRoot
    scanTimestampUtc = $ScanTimestampUtc
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    groupCount = $normalizedGroups.Count
    groups = @($normalizedGroups)
}

if (-not $OutputPath) {
    $OutputPath = [System.IO.Path]::ChangeExtension($InputPath, '.normalized.json')
}

$directory = Split-Path -Path $OutputPath -Parent
if ($directory -and -not (Test-Path -Path $directory)) {
    New-Item -Path $directory -ItemType Directory -Force | Out-Null
}

$normalizedDoc | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputPath -Encoding UTF8

[pscustomobject]@{
    schemaVersion = 1
    inputPath = $InputPath
    outputPath = $OutputPath
    groupCount = $normalizedGroups.Count
    mode = $Mode
}
