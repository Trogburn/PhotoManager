[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputPath,

    [Parameter()]
    [string]$ScanReportDir,

    [Parameter()]
    [string]$OutputPath,

    [ValidateSet('auto', 'grouped', 'flat')]
    [string]$Mode = 'auto',

    [string]$SourceScan = 'raw-czkawka',

    [string]$CzkawkaVersion,

    [string]$ScanRoot,

    [string]$ScanTimestampUtc,

    [string]$RawArtifactPath,

    [string]$GeneratedAtUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Property {
    param(
        [object]$Target,
        [string]$PropertyName
    )

    if ($null -eq $Target) { return $false }
    if ($Target -is [string] -or $Target -is [System.Array] -or $Target -is [System.ValueType]) { return $false }
    try {
        return @($Target.PSObject.Properties | ForEach-Object { $_.Name }) -contains $PropertyName
    }
    catch {
        return $false
    }
}

function Test-IsArray {
    param([object]$Target)

    if ($null -eq $Target) { return $false }
    if ($Target -is [string]) { return $false }
    return $Target -is [System.Array] -or $Target -is [System.Collections.IList]
}

function Convert-HashValue {
    param([object]$RawHash)

    if ($null -eq $RawHash) { return $null }
    if ($RawHash -is [string]) {
        if ([string]::IsNullOrWhiteSpace($RawHash)) { return $null }
        return [string]$RawHash
    }
    if (($RawHash -is [System.Array] -or $RawHash -is [System.Collections.IList]) -and $RawHash -isnot [string]) {
        $bytes = @($RawHash)
        if ($bytes.Count -eq 0) { return $null }
        return (($bytes | ForEach-Object { '{0:x2}' -f ([int]$_) }) -join '')
    }
    return [string]$RawHash
}

function Convert-ModifiedTime {
    param([object]$Entry)

    if (Test-Property -Target $Entry -PropertyName 'modifiedTime') {
        return [string]$Entry.modifiedTime
    }
    if (Test-Property -Target $Entry -PropertyName 'mtime') {
        return [string]$Entry.mtime
    }
    if (Test-Property -Target $Entry -PropertyName 'modified_date') {
        $raw = $Entry.modified_date
        if ($raw -is [string] -and $raw -match 'T') {
            return [string]$raw
        }
        $seconds = [long]$raw
        if ($seconds -le 0) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime.ToString('o')
    }
    return $null
}

function Test-ReferencedPair {
    param([object]$Group)

    $items = @($Group)
    if ($items.Count -ne 2) { return $false }
    $first = $items[0]
    $second = $items[1]
    if ($null -eq $first -or $null -eq $second) { return $false }
    $firstLooksLikeEntry = (Test-Property -Target $first -PropertyName 'path') -or (Test-Property -Target $first -PropertyName 'modified_date') -or (Test-Property -Target $first -PropertyName 'hash')
    return $firstLooksLikeEntry -and (Test-IsArray -Target $second)
}

function New-NormalizedEntry {
    param(
        [object]$Entry,
        [string]$SourceScan,
        [string]$GroupId,
        [bool]$IsReference = $false,
        [string]$ReferenceState = 'not-set'
    )

    $pathValue = if (Test-Property -Target $Entry -PropertyName 'path') { [string]$Entry.path } elseif (Test-Property -Target $Entry -PropertyName 'name') { [string]$Entry.name } else { '' }
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        throw "Result entry is missing a path in $InputPath."
    }

    $sizeValue = if (Test-Property -Target $Entry -PropertyName 'size') { [long]$Entry.size } else { 0 }
    $hashValue = $null
    if (Test-Property -Target $Entry -PropertyName 'hash') {
        $hashValue = Convert-HashValue -RawHash $Entry.hash
    }
    elseif (Test-Property -Target $Entry -PropertyName 'hashes') {
        $hashValue = Convert-HashValue -RawHash $Entry.hashes
    }

    $differenceValue = $null
    if (Test-Property -Target $Entry -PropertyName 'difference') {
        $differenceValue = [double]$Entry.difference
    }
    elseif (Test-Property -Target $Entry -PropertyName 'perceptualDifference') {
        $differenceValue = [double]$Entry.perceptualDifference
    }

    $entryIsReference = if (Test-Property -Target $Entry -PropertyName 'isReference') { [bool]$Entry.isReference } else { $IsReference }
    $entryReferenceState = if (Test-Property -Target $Entry -PropertyName 'referenceState') { [string]$Entry.referenceState } else { $ReferenceState }

    return [ordered]@{
        path = $pathValue
        size = $sizeValue
        modifiedTime = Convert-ModifiedTime -Entry $Entry
        hash = $hashValue
        width = if (Test-Property -Target $Entry -PropertyName 'width') { [int]$Entry.width } else { $null }
        height = if (Test-Property -Target $Entry -PropertyName 'height') { [int]$Entry.height } else { $null }
        perceptualDifference = $differenceValue
        sourceScan = $SourceScan
        groupId = $GroupId
        isReference = $entryIsReference
        referenceState = $entryReferenceState
        warning = if (Test-Property -Target $Entry -PropertyName 'warning') { [string]$Entry.warning } else { $null }
        accessState = if (Test-Property -Target $Entry -PropertyName 'access') { [string]$Entry.access } else { 'accessible' }
        error = if (Test-Property -Target $Entry -PropertyName 'error') { [string]$Entry.error } else { $null }
        isStale = if (Test-Property -Target $Entry -PropertyName 'stale') { [bool]$Entry.stale } else { $false }
        staleReason = if (Test-Property -Target $Entry -PropertyName 'staleReason') { [string]$Entry.staleReason } else { $null }
    }
}

function New-NormalizedGroup {
    param(
        [string]$GroupId,
        [string]$Kind,
        [bool]$IsReference,
        [object[]]$Entries,
        [object[]]$Warnings = @()
    )

    return [ordered]@{
        schemaVersion = 1
        source = 'czkawka'
        groupId = $GroupId
        kind = $Kind
        isReference = $IsReference
        warnings = @($Warnings)
        entries = @($Entries)
    }
}

function Get-DocumentKind {
    param(
        [object]$Parsed,
        [string]$RequestedMode,
        [string]$SourcePath
    )

    if ($RequestedMode -eq 'grouped' -or $RequestedMode -eq 'flat') {
        return $RequestedMode
    }

    if ($null -eq $Parsed) {
        return 'empty'
    }

    if (Test-IsArray -Target $Parsed) {
        $items = @($Parsed)
        if ($items.Count -eq 0) { return 'empty' }
        $first = $items[0]
        if ((Test-Property -Target $first -PropertyName 'groupId') -or (Test-Property -Target $first -PropertyName 'entries')) {
            return 'grouped'
        }
        if (Test-IsArray -Target $first) {
            if (Test-ReferencedPair -Group $first) { return 'czkawka-image-reference' }
            return 'czkawka-image'
        }
        if (Test-ReferencedPair -Group $Parsed) {
            return 'czkawka-image-reference-single'
        }
        if ((Test-Property -Target $first -PropertyName 'modified_date') -and ((Test-Property -Target $first -PropertyName 'width') -or (Test-Property -Target $first -PropertyName 'difference') -or (Test-Property -Target $first -PropertyName 'hashes'))) {
            return 'czkawka-image-single-group'
        }
        if ((Test-Property -Target $first -PropertyName 'path') -or (Test-Property -Target $first -PropertyName 'name')) {
            return 'flat'
        }
        throw "Unsupported JSON result shape in $SourcePath. Expected an array of groups or file entries."
    }

    $names = @($Parsed.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names.Count -eq 0) { return 'empty' }
    if ($names -contains 'schemaVersion' -and $names -contains 'groups') { return 'normalized' }
    if ($names -contains 'entries' -or $names -contains 'groupId') { return 'grouped' }
    if ($names -contains 'path' -or $names -contains 'name') { return 'flat' }
    $nonNumeric = @($names | Where-Object { $_ -notmatch '^\d+$' })
    if ($nonNumeric.Count -eq 0) {
        $firstProperty = $Parsed.PSObject.Properties | Select-Object -First 1
        $firstGroup = @(@($firstProperty.Value)[0])
        if (Test-ReferencedPair -Group $firstGroup) { return 'czkawka-dup-hash-reference' }
        return 'czkawka-dup-hash'
    }

    throw "Unsupported JSON result shape in $SourcePath. Expected an array of groups or file entries."
}

function Convert-CzkawkaHashGroups {
    param(
        [object]$Parsed,
        [string]$SourceScan,
        [switch]$Referenced
    )

    $groups = @()
    $sizeIndex = 0
    foreach ($property in $Parsed.PSObject.Properties) {
        $sizeGroups = @($property.Value)
        $groupIndex = 0
        foreach ($sizeGroup in $sizeGroups) {
            $groupId = "dup-hash-$($property.Name)-$groupIndex"
            if ($Referenced -or (Test-ReferencedPair -Group $sizeGroup)) {
                $pair = @($sizeGroup)
                $referenceEntry = New-NormalizedEntry -Entry $pair[0] -SourceScan $SourceScan -GroupId $groupId -IsReference $true -ReferenceState 'reference'
                $candidates = @()
                foreach ($candidate in @($pair[1])) {
                    if ($null -ne $candidate) {
                        $candidates += New-NormalizedEntry -Entry $candidate -SourceScan $SourceScan -GroupId $groupId -IsReference $false -ReferenceState 'candidate'
                    }
                }
                $groups += New-NormalizedGroup -GroupId $groupId -Kind 'duplicate' -IsReference $true -Entries (@($referenceEntry) + $candidates)
            }
            else {
                $entries = @()
                foreach ($entry in @($sizeGroup)) {
                    if ($null -ne $entry) {
                        $entries += New-NormalizedEntry -Entry $entry -SourceScan $SourceScan -GroupId $groupId
                    }
                }
                $groups += New-NormalizedGroup -GroupId $groupId -Kind 'duplicate' -IsReference $false -Entries $entries
            }
            $groupIndex++
        }
        $sizeIndex++
    }
    return @($groups)
}

function Convert-CzkawkaImageGroups {
    param(
        [object]$Parsed,
        [string]$SourceScan,
        [switch]$Referenced
    )

    $groups = @()
    $groupIndex = 0
    foreach ($imageGroup in @($Parsed)) {
        $groupId = "image-$groupIndex"
        if ($Referenced -or (Test-ReferencedPair -Group $imageGroup)) {
            $pair = @($imageGroup)
            $referenceEntry = New-NormalizedEntry -Entry $pair[0] -SourceScan $SourceScan -GroupId $groupId -IsReference $true -ReferenceState 'reference'
            $candidates = @()
            foreach ($candidate in @($pair[1])) {
                if ($null -ne $candidate) {
                    $candidates += New-NormalizedEntry -Entry $candidate -SourceScan $SourceScan -GroupId $groupId -IsReference $false -ReferenceState 'candidate'
                }
            }
            $groups += New-NormalizedGroup -GroupId $groupId -Kind 'similar-image' -IsReference $true -Entries (@($referenceEntry) + $candidates)
        }
        else {
            $entries = @()
            foreach ($entry in @($imageGroup)) {
                if ($null -ne $entry) {
                    $entries += New-NormalizedEntry -Entry $entry -SourceScan $SourceScan -GroupId $groupId
                }
            }
            $groups += New-NormalizedGroup -GroupId $groupId -Kind 'similar-image' -IsReference $false -Entries $entries
        }
        $groupIndex++
    }
    return @($groups)
}

function Convert-ToNormalizedDocument {
    param(
        [object]$Parsed,
        [string]$ResolvedInputPath,
        [string]$ResolvedRawArtifactPath,
        [string]$ResolvedSourceScan,
        [string]$ResolvedVersion,
        [string]$ResolvedScanRoot,
        [string]$ResolvedScanTimestampUtc,
        [string]$ResolvedGeneratedAtUtc,
        [string]$RequestedMode
    )

    $kind = Get-DocumentKind -Parsed $Parsed -RequestedMode $RequestedMode -SourcePath $ResolvedInputPath
    $normalizedGroups = @()

    switch ($kind) {
        'empty' { $normalizedGroups = @() }
        'normalized' { $normalizedGroups = @($Parsed.groups) }
        'czkawka-dup-hash' { $normalizedGroups = Convert-CzkawkaHashGroups -Parsed $Parsed -SourceScan $ResolvedSourceScan }
        'czkawka-dup-hash-reference' { $normalizedGroups = Convert-CzkawkaHashGroups -Parsed $Parsed -SourceScan $ResolvedSourceScan -Referenced }
        'czkawka-image' { $normalizedGroups = Convert-CzkawkaImageGroups -Parsed $Parsed -SourceScan $ResolvedSourceScan }
        'czkawka-image-single-group' { $normalizedGroups = Convert-CzkawkaImageGroups -Parsed @(, $Parsed) -SourceScan $ResolvedSourceScan }
        'czkawka-image-reference' { $normalizedGroups = Convert-CzkawkaImageGroups -Parsed $Parsed -SourceScan $ResolvedSourceScan -Referenced }
        'czkawka-image-reference-single' { $normalizedGroups = Convert-CzkawkaImageGroups -Parsed @(, $Parsed) -SourceScan $ResolvedSourceScan -Referenced }
        'grouped' {
            $groupIndex = 0
            foreach ($group in @($Parsed)) {
                if (-not (Test-Property -Target $group -PropertyName 'entries')) {
                    throw "Grouped result at index $groupIndex is missing an entries array in $ResolvedInputPath."
                }
                $groupId = if (Test-Property -Target $group -PropertyName 'groupId') { [string]$group.groupId } else { "group-$groupIndex" }
                $entries = @()
                foreach ($entry in @($group.entries)) {
                    if ($null -ne $entry) {
                        $entries += New-NormalizedEntry -Entry $entry -SourceScan $ResolvedSourceScan -GroupId $groupId
                    }
                }
                $kindValue = if (Test-Property -Target $group -PropertyName 'kind') { [string]$group.kind } else { 'unknown' }
                $isReferenceValue = if (Test-Property -Target $group -PropertyName 'isReference') { [bool]$group.isReference } else { $false }
                $warningValue = if (Test-Property -Target $group -PropertyName 'warnings') { @($group.warnings) } else { @() }
                $normalizedGroups += New-NormalizedGroup -GroupId $groupId -Kind $kindValue -IsReference $isReferenceValue -Entries $entries -Warnings $warningValue
                $groupIndex++
            }
        }
        'flat' {
            $itemIndex = 0
            foreach ($item in @($Parsed)) {
                $groupId = if (Test-Property -Target $item -PropertyName 'groupId') { [string]$item.groupId } else { "group-$itemIndex" }
                $isReferenceValue = if (Test-Property -Target $item -PropertyName 'isReference') { [bool]$item.isReference } else { $false }
                $normalizedGroups += New-NormalizedGroup -GroupId $groupId -Kind 'flat' -IsReference $isReferenceValue -Entries @(New-NormalizedEntry -Entry $item -SourceScan $ResolvedSourceScan -GroupId $groupId)
                $itemIndex++
            }
        }
        default {
            throw "Unsupported parse mode: $kind"
        }
    }

    return [ordered]@{
        schemaVersion = 1
        source = 'czkawka'
        inputPath = $ResolvedInputPath
        rawArtifactPath = $ResolvedRawArtifactPath
        sourceScan = $ResolvedSourceScan
        czkawkaVersion = $ResolvedVersion
        scanRoot = $ResolvedScanRoot
        scanTimestampUtc = $ResolvedScanTimestampUtc
        generatedAtUtc = $ResolvedGeneratedAtUtc
        groupCount = @($normalizedGroups).Count
        groups = @($normalizedGroups)
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input result file not found: $Path"
    }
    $rawJson = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        throw "Input result file is empty: $Path"
    }
    try {
        return $rawJson | ConvertFrom-Json
    }
    catch {
        throw ("Malformed JSON in {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

function Write-JsonFile {
    param(
        [object]$Document,
        [string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    $Document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Convert-ToIsoTimestamp {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }
    if ($Value -is [datetime]) {
        $dateTime = [datetime]$Value
        if ($dateTime.Kind -eq [DateTimeKind]::Local) {
            return $dateTime.ToUniversalTime().ToString('o')
        }
        return [DateTime]::SpecifyKind($dateTime, [DateTimeKind]::Utc).ToString('o')
    }
    return [string]$Value
}

function Get-MetadataValue {
    param(
        [object]$Metadata,
        [string]$PropertyName,
        [string]$Fallback
    )

    if ($null -ne $Metadata -and $null -ne $Metadata.PSObject.Properties[$PropertyName] -and -not [string]::IsNullOrWhiteSpace([string]$Metadata.$PropertyName)) {
        return [string]$Metadata.$PropertyName
    }
    return $Fallback
}

$effectiveGeneratedAtUtc = if ($GeneratedAtUtc) { $GeneratedAtUtc } else { (Get-Date).ToUniversalTime().ToString('o') }

if ($ScanReportDir) {
    if (-not (Test-Path -LiteralPath $ScanReportDir)) {
        throw "Scan report directory not found: $ScanReportDir"
    }
    $summaryPath = Join-Path $ScanReportDir 'summary.json'
    $summary = if (Test-Path -LiteralPath $summaryPath) { Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json } else { $null }
    $dupRaw = Join-Path $ScanReportDir 'raw\dup.json'
    $imageRaw = Join-Path $ScanReportDir 'raw\image.json'
    $dupMetadata = $null
    $imageMetadata = $null
    $dupMetaPath = Join-Path $ScanReportDir 'metadata\dup.metadata.json'
    $imageMetaPath = Join-Path $ScanReportDir 'metadata\image.metadata.json'
    if (Test-Path -LiteralPath $dupMetaPath) { $dupMetadata = Get-Content -LiteralPath $dupMetaPath -Raw | ConvertFrom-Json }
    if (Test-Path -LiteralPath $imageMetaPath) { $imageMetadata = Get-Content -LiteralPath $imageMetaPath -Raw | ConvertFrom-Json }

    $resolvedScanRoot = if ($ScanRoot) { $ScanRoot } elseif ($summary) { [string]$summary.scanRoot } else { Get-MetadataValue -Metadata $dupMetadata -PropertyName 'scanRoot' -Fallback '' }
    $resolvedVersion = if ($CzkawkaVersion) { $CzkawkaVersion } elseif ($summary) { [string]$summary.czkawkaVersion } else { Get-MetadataValue -Metadata $dupMetadata -PropertyName 'czkawkaVersion' -Fallback '' }
    $resolvedTimestamp = if ($ScanTimestampUtc) {
        Convert-ToIsoTimestamp -Value $ScanTimestampUtc
    }
    elseif ($dupMetadata -and $null -ne $dupMetadata.PSObject.Properties['startUtc']) {
        Convert-ToIsoTimestamp -Value $dupMetadata.startUtc
    }
    elseif ($summary -and $null -ne $summary.PSObject.Properties['scanCompletedUtc']) {
        Convert-ToIsoTimestamp -Value $summary.scanCompletedUtc
    }
    else {
        $effectiveGeneratedAtUtc
    }

    $normalizedDir = Join-Path $ScanReportDir 'normalized'
    New-Item -Path $normalizedDir -ItemType Directory -Force | Out-Null
    $dupNormalizedPath = Join-Path $normalizedDir 'dup.normalized.json'
    $imageNormalizedPath = Join-Path $normalizedDir 'image.normalized.json'
    $combinedPath = if ($OutputPath) { $OutputPath } else { Join-Path $normalizedDir 'combined.normalized.json' }

    $dupDoc = Convert-ToNormalizedDocument -Parsed (Read-JsonFile -Path $dupRaw) -ResolvedInputPath $dupRaw -ResolvedRawArtifactPath $dupRaw -ResolvedSourceScan 'dup' -ResolvedVersion $resolvedVersion -ResolvedScanRoot $resolvedScanRoot -ResolvedScanTimestampUtc $resolvedTimestamp -ResolvedGeneratedAtUtc $effectiveGeneratedAtUtc -RequestedMode 'auto'
    $imageDoc = Convert-ToNormalizedDocument -Parsed (Read-JsonFile -Path $imageRaw) -ResolvedInputPath $imageRaw -ResolvedRawArtifactPath $imageRaw -ResolvedSourceScan 'image' -ResolvedVersion $resolvedVersion -ResolvedScanRoot $resolvedScanRoot -ResolvedScanTimestampUtc $resolvedTimestamp -ResolvedGeneratedAtUtc $effectiveGeneratedAtUtc -RequestedMode 'auto'
    Write-JsonFile -Document $dupDoc -Path $dupNormalizedPath
    Write-JsonFile -Document $imageDoc -Path $imageNormalizedPath

    $combinedGroups = @(@($dupDoc.groups) + @($imageDoc.groups))
    $combined = [ordered]@{
        schemaVersion = 1
        source = 'czkawka'
        inputPath = $ScanReportDir
        rawArtifactPath = @($dupRaw, $imageRaw)
        sourceScan = @('dup', 'image')
        czkawkaVersion = $resolvedVersion
        scanRoot = $resolvedScanRoot
        scanTimestampUtc = $resolvedTimestamp
        generatedAtUtc = $effectiveGeneratedAtUtc
        rawArtifactPaths = [ordered]@{
            dup = $dupRaw
            image = $imageRaw
        }
        metadataPaths = [ordered]@{
            dup = $dupMetaPath
            image = $imageMetaPath
            summary = $summaryPath
        }
        groupCount = $combinedGroups.Count
        groups = $combinedGroups
    }
    Write-JsonFile -Document $combined -Path $combinedPath

    return [pscustomobject]@{
        schemaVersion = 1
        scanReportDir = $ScanReportDir
        outputPath = $combinedPath
        dupNormalizedPath = $dupNormalizedPath
        imageNormalizedPath = $imageNormalizedPath
        groupCount = $combined.groupCount
        czkawkaVersion = $resolvedVersion
        scanRoot = $resolvedScanRoot
        scanTimestampUtc = $resolvedTimestamp
        rawArtifactPaths = @($dupRaw, $imageRaw)
        mode = 'combined'
    }
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    throw 'InputPath is required unless -ScanReportDir is provided.'
}

$parsed = Read-JsonFile -Path $InputPath
$resolvedRaw = if ($RawArtifactPath) { $RawArtifactPath } else { $InputPath }
if (-not $OutputPath) {
    $OutputPath = [IO.Path]::ChangeExtension($InputPath, '.normalized.json')
}

$normalizedDoc = Convert-ToNormalizedDocument -Parsed $parsed -ResolvedInputPath $InputPath -ResolvedRawArtifactPath $resolvedRaw -ResolvedSourceScan $SourceScan -ResolvedVersion $CzkawkaVersion -ResolvedScanRoot $ScanRoot -ResolvedScanTimestampUtc $ScanTimestampUtc -ResolvedGeneratedAtUtc $effectiveGeneratedAtUtc -RequestedMode $Mode
Write-JsonFile -Document $normalizedDoc -Path $OutputPath

[pscustomobject]@{
    schemaVersion = 1
    inputPath = $InputPath
    outputPath = $OutputPath
    groupCount = $normalizedDoc.groupCount
    mode = $Mode
    czkawkaVersion = $CzkawkaVersion
    scanRoot = $ScanRoot
    rawArtifactPath = $resolvedRaw
}
