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
    $arguments = @{
        InputPath = (Join-Path $fixtures $Fixture)
        OutputPath = $output
        SourceScan = 'image'
        CzkawkaVersion = '12.0.1'
        ScanRoot = '\\NAS\Photos'
        ScanTimestampUtc = '2026-09-08T00:00:00Z'
        RawArtifactPath = (Join-Path $fixtures $Fixture)
    }
    if ($Mode -ne 'auto') {
        $arguments.Mode = $Mode
    }

    & $parser @arguments | Out-Null
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
