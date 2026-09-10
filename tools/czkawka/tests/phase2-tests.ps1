[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parser = Join-Path $PSScriptRoot '..\parse-results.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$temp = Join-Path $PSScriptRoot 'temp'
New-Item -Path $temp -ItemType Directory -Force | Out-Null

function Invoke-Parser {
    param(
        [string]$Fixture,
        [string]$Name,
        [string]$Mode = 'auto'
    )

    $output = Join-Path $temp "$Name.normalized.json"
    $parserArgs = @{
        InputPath = (Join-Path $fixtures $Fixture)
        OutputPath = $output
        SourceScan = 'image'
        CzkawkaVersion = '12.0.1'
        ScanRoot = '\\NAS\Photos'
        ScanTimestampUtc = '2026-09-08T00:00:00Z'
        RawArtifactPath = (Join-Path $fixtures $Fixture)
        GeneratedAtUtc = '2026-09-08T00:00:00Z'
    }
    if ($Mode -ne 'auto') {
        $parserArgs.Mode = $Mode
    }

    & $parser @parserArgs | Out-Null
    return Get-Content -Path $output -Raw | ConvertFrom-Json
}

$image = Invoke-Parser -Fixture 'image-group.json' -Name 'image'
if ($image.groupCount -ne 1 -or $image.groups[0].entries.Count -ne 2) {
    throw 'Image group did not normalize to one group with two entries.'
}
if ($image.groups[0].entries[0].path -ne '\\NAS\Photos\Reference\original.jpg') {
    throw 'UNC path did not round-trip unchanged.'
}
if ($image.groups[0].entries[0].width -ne 1920 -or $image.groups[0].entries[1].perceptualDifference -ne 3.5) {
    throw 'Image dimensions or perceptual difference did not normalize.'
}
if ($image.scanRoot -ne '\\NAS\Photos' -or $image.czkawkaVersion -ne '12.0.1' -or $image.rawArtifactPath -notlike '*image-group.json') {
    throw 'Scan metadata was not preserved.'
}

$empty = Invoke-Parser -Fixture 'empty.json' -Name 'empty'
if ($empty.groupCount -ne 0 -or $empty.groups.Count -ne 0) {
    throw 'Empty result did not normalize to zero groups.'
}

$flat = Invoke-Parser -Fixture 'dup-flat.json' -Name 'flat'
if ($flat.groupCount -ne 2 -or $flat.groups[0].groupId -ne 'group-0' -or $flat.groups[1].groupId -ne 'group-1') {
    throw 'Flat results did not receive deterministic group IDs.'
}

$reference = Invoke-Parser -Fixture 'dup-reference.json' -Name 'reference'
if (-not $reference.groups[0].isReference -or $reference.groups[0].entries[0].referenceState -ne 'reference') {
    throw 'Duplicate reference-directory state did not normalize.'
}

$warnings = Invoke-Parser -Fixture 'warnings.json' -Name 'warnings'
if (@($warnings.groups[0].warnings).Count -ne 1 -or $warnings.groups[0].entries[0].warning -ne 'metadata unavailable') {
    throw 'Warning evidence did not normalize.'
}

$inaccessible = Invoke-Parser -Fixture 'inaccessible.json' -Name 'inaccessible'
if ($inaccessible.groups[0].entries[0].accessState -ne 'inaccessible' -or $inaccessible.groups[0].entries[0].error -ne 'Access denied') {
    throw 'Inaccessible-file evidence did not normalize.'
}

$stale = Invoke-Parser -Fixture 'stale.json' -Name 'stale'
if (-not $stale.groups[0].entries[0].isStale -or $stale.groups[0].entries[0].staleReason -ne 'size-or-time-changed') {
    throw 'Stale-file evidence did not normalize.'
}

$czkawkaDup = Invoke-Parser -Fixture 'czkawka-dup-hash.json' -Name 'czkawka-dup'
if ($czkawkaDup.groupCount -ne 1 -or @($czkawkaDup.groups[0].entries).Count -ne 2) {
    throw 'Captured Czkawka HASH JSON did not normalize to one duplicate group.'
}
if ($czkawkaDup.groups[0].kind -ne 'duplicate' -or $czkawkaDup.groups[0].entries[0].path -ne '\\NAS\Photos\incoming\original-copy.jpg') {
    throw 'Czkawka HASH paths did not round-trip unchanged.'
}
$expectedUnix = [DateTimeOffset]::FromUnixTimeSeconds(1700000000).UtcDateTime
$actualModified = [datetime]$czkawkaDup.groups[0].entries[0].modifiedTime
if ($actualModified.ToUniversalTime() -ne $expectedUnix) {
    throw "Czkawka HASH modified_date did not convert to UTC. Expected $expectedUnix, got $actualModified"
}
if ($czkawkaDup.groups[0].entries[0].hash -ne 'd6ddf9df546a5209d79e47f1de940051e1fbda19422841b90f913ef45340ce58') {
    throw 'Czkawka HASH digest was not preserved.'
}

$czkawkaImage = Invoke-Parser -Fixture 'czkawka-image.json' -Name 'czkawka-image'
if ($czkawkaImage.groupCount -ne 1 -or $czkawkaImage.groups[0].kind -ne 'similar-image') {
    throw 'Captured Czkawka image JSON did not normalize to one similar-image group.'
}
if ($czkawkaImage.groups[0].entries[0].width -ne 96 -or $czkawkaImage.groups[0].entries[1].perceptualDifference -ne 0) {
    throw 'Czkawka image dimensions or difference did not normalize.'
}

$czkawkaDupRef = Invoke-Parser -Fixture 'czkawka-dup-hash-reference.json' -Name 'czkawka-dup-ref'
if (-not $czkawkaDupRef.groups[0].isReference -or $czkawkaDupRef.groups[0].entries[0].referenceState -ne 'reference' -or $czkawkaDupRef.groups[0].entries[1].referenceState -ne 'candidate') {
    throw 'Czkawka HASH reference-directory variant did not normalize.'
}

$czkawkaImageRef = Invoke-Parser -Fixture 'czkawka-image-reference.json' -Name 'czkawka-image-ref'
if (-not $czkawkaImageRef.groups[0].isReference -or $czkawkaImageRef.groups[0].entries[0].path -ne '\\NAS\Reference\original.jpg') {
    throw 'Czkawka image reference-directory variant did not normalize.'
}
if ($czkawkaImageRef.groups[0].entries[0].hash -ne '01020304' -or $czkawkaImageRef.groups[0].entries[1].perceptualDifference -ne 3) {
    throw 'Czkawka image reference hash bytes or difference did not normalize.'
}

$czkawkaEmpty = Invoke-Parser -Fixture 'czkawka-dup-empty.json' -Name 'czkawka-dup-empty'
if ($czkawkaEmpty.groupCount -ne 0) {
    throw 'Empty Czkawka HASH object did not normalize to zero groups.'
}

$generatedAt = '2026-09-09T00:00:00.0000000Z'
$firstPath = Join-Path $temp 'deterministic-a.json'
$secondPath = Join-Path $temp 'deterministic-b.json'
$parserArgs = @{
    InputPath = (Join-Path $fixtures 'czkawka-dup-hash.json')
    SourceScan = 'dup'
    CzkawkaVersion = '12.0.1'
    ScanRoot = '\\NAS\Photos'
    ScanTimestampUtc = '2026-09-08T00:00:00Z'
    RawArtifactPath = (Join-Path $fixtures 'czkawka-dup-hash.json')
    GeneratedAtUtc = $generatedAt
}
& $parser @parserArgs -OutputPath $firstPath | Out-Null
& $parser @parserArgs -OutputPath $secondPath | Out-Null
if ((Get-Content -LiteralPath $firstPath -Raw) -ne (Get-Content -LiteralPath $secondPath -Raw)) {
    throw 'Normalized Czkawka HASH output was not byte-for-byte deterministic.'
}

$scanDir = Join-Path $temp 'scan-combined'
New-Item -Path (Join-Path $scanDir 'raw') -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $scanDir 'metadata') -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $fixtures 'czkawka-dup-hash.json') -Destination (Join-Path $scanDir 'raw\dup.json')
Copy-Item -LiteralPath (Join-Path $fixtures 'czkawka-image.json') -Destination (Join-Path $scanDir 'raw\image.json')
@{
    schemaVersion = 1
    mode = 'dup'
    scanRoot = '\\NAS\Photos'
    czkawkaVersion = 'czkawka 12.0.1'
    startUtc = '2026-09-09T12:00:00Z'
    rawOutput = (Join-Path $scanDir 'raw\dup.json')
    standardError = (Join-Path $scanDir 'diagnostics\dup.stderr.log')
    exitCode = 0
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scanDir 'metadata\dup.metadata.json') -Encoding utf8
@{
    schemaVersion = 1
    mode = 'image'
    scanRoot = '\\NAS\Photos'
    czkawkaVersion = 'czkawka 12.0.1'
    startUtc = '2026-09-09T12:00:00Z'
    rawOutput = (Join-Path $scanDir 'raw\image.json')
    standardError = (Join-Path $scanDir 'diagnostics\image.stderr.log')
    exitCode = 0
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scanDir 'metadata\image.metadata.json') -Encoding utf8
@{
    schemaVersion = 1
    scanRoot = '\\NAS\Photos'
    czkawkaVersion = 'czkawka 12.0.1'
    scanCompletedUtc = '2026-09-09T12:00:01Z'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scanDir 'summary.json') -Encoding utf8

$combined = & $parser -ScanReportDir $scanDir -GeneratedAtUtc $generatedAt | Select-Object -Last 1
$combinedRaw = Get-Content -LiteralPath $combined.outputPath -Raw
$combinedDoc = $combinedRaw | ConvertFrom-Json
if ($combinedDoc.czkawkaVersion -ne 'czkawka 12.0.1' -or $combinedDoc.scanRoot -ne '\\NAS\Photos' -or $combinedRaw -notmatch '"scanTimestampUtc":\s*"2026-09-09T12:00:00') {
    throw "Combined workflow did not preserve Czkawka version, scan root, and scan timestamp. version=$($combinedDoc.czkawkaVersion) root=$($combinedDoc.scanRoot) timestamp=$($combinedDoc.scanTimestampUtc)"
}
if ($combinedDoc.rawArtifactPaths.dup -notlike '*dup.json' -or $combinedDoc.rawArtifactPaths.image -notlike '*image.json') {
    throw 'Combined workflow did not preserve raw artifact paths.'
}
if ($combinedDoc.groupCount -ne 2 -or $combinedDoc.groups[0].entries[0].sourceScan -ne 'dup' -or $combinedDoc.groups[1].entries[0].sourceScan -ne 'image') {
    throw 'Combined workflow did not retain source scan identity on normalized groups.'
}
$combinedAgain = & $parser -ScanReportDir $scanDir -OutputPath (Join-Path $temp 'combined-b.json') -GeneratedAtUtc $generatedAt | Select-Object -Last 1
if ((Get-Content -LiteralPath $combined.outputPath -Raw) -ne (Get-Content -LiteralPath $combinedAgain.outputPath -Raw)) {
    throw 'Combined workflow output was not byte-for-byte deterministic.'
}

$malformed = Join-Path $temp 'malformed.json'
'{ not valid json' | Set-Content -Path $malformed -Encoding UTF8
try {
    & $parser -InputPath $malformed -OutputPath (Join-Path $temp 'malformed.normalized.json') 2>&1 | Out-Null
    throw 'Malformed JSON unexpectedly succeeded.'
}
catch {
    if ($_.Exception.Message -notlike '*Malformed JSON*') {
        throw "Malformed JSON error was not actionable: $($_.Exception.Message)"
    }
}

$unsupported = Join-Path $temp 'unsupported.json'
'{"unexpected":true}' | Set-Content -Path $unsupported -Encoding UTF8
try {
    & $parser -InputPath $unsupported -OutputPath (Join-Path $temp 'unsupported.normalized.json') 2>&1 | Out-Null
    throw 'Unsupported shape unexpectedly succeeded.'
}
catch {
    if ($_.Exception.Message -notlike '*Unsupported JSON result shape*') {
        throw "Unsupported shape error was not actionable: $($_.Exception.Message)"
    }
}

Write-Host 'Phase 2 parser tests passed.'
