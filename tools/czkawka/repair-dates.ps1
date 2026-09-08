[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,

    [Parameter()]
    [string]$OutputPath = '.\reports\dates\date-review.json',

    [Parameter()]
    [ValidateSet('CreationTimeOnly', 'CreationAndLastWriteTime')]
    [string]$Policy = 'CreationTimeOnly',

    [Parameter()]
    [switch]$Recurse,

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [string[]]$ApprovePath,

    [Parameter()]
    [switch]$Undo,

    [Parameter()]
    [string]$ReviewPath,

    [Parameter()]
    [string]$DecisionPath,

    [Parameter()]
    [string]$UndoManifestPath = '.\reports\dates\date-undo.jsonl',

    [Parameter()]
    [datetime]$FutureToleranceUtc = (Get-Date).ToUniversalTime().AddDays(1)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param(
        [object]$Value,
        [string]$Name
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) {
        return $null
    }
    return $Value.PSObject.Properties[$Name].Value
}

function Test-FileTimeMatch {
    param(
        [datetime]$Actual,
        [object]$Expected
    )

    $expectedDate = if ($Expected -is [datetime]) { ([datetime]$Expected).ToUniversalTime() } else { [datetime]::Parse([string]$Expected).ToUniversalTime() }
    return [math]::Abs(($Actual.ToUniversalTime() - $expectedDate).TotalSeconds) -le 1
}

function Convert-ToDateOffset {
    param(
        [string]$RawValue,
        [string]$Source
    )

    $parsed = [datetimeoffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces
    if ($RawValue -match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$') {
        $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeLocal
        if (-not [datetimeoffset]::TryParseExact($RawValue, 'yyyy:MM:dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue" }
        }
    }
    elseif (-not [datetimeoffset]::TryParse($RawValue, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue" }
    }

    return [pscustomobject]@{ Valid = $true; Date = $parsed; Error = $null }
}

function Get-DateEvidenceFromName {
    param([System.IO.FileInfo]$File)

    if ($File.Extension.ToLowerInvariant() -in @('.xmp', '.aae', '.json', '.xml')) {
        return $null
    }

    $name = $File.BaseName
    $match = [regex]::Match($name, '(?<date>20\d{2}[-_]?(?<month>0[1-9]|1[0-2])[-_]?(?<day>0[1-9]|[12]\d|3[01]))(?:[T _-]?(?<time>[0-2]\d[0-5]\d[0-5]\d))?')
    if (-not $match.Success) {
        $invalidToken = [regex]::Match($name, '20\d{2}[-_]?\d{2}[-_]?\d{2}')
        if ($invalidToken.Success) {
            return [pscustomobject]@{ Source = 'filename'; RawValue = $invalidToken.Value; Date = $null; Error = "Invalid or ambiguous filename date: $($invalidToken.Value)"; Token = $invalidToken.Value }
        }
        return $null
    }

    $dateToken = $match.Groups['date'].Value
    $timeToken = $match.Groups['time'].Value
    $rawValue = if ($timeToken) { "$dateToken $timeToken" } else { $dateToken }
    $format = if ($timeToken) { 'yyyy-MM-dd HHmmss' } else { 'yyyy-MM-dd' }
    $normalized = $dateToken -replace '_', '-' -replace '(?<!^)(\d{4})(\d{2})(\d{2})$', '$1-$2-$3'
    if ($normalized -notmatch '^\d{4}-\d{2}-\d{2}$') {
        $normalized = $normalized -replace '^(\d{4})(\d{2})(\d{2})$', '$1-$2-$3'
    }
    $normalizedRaw = if ($timeToken) { "$normalized $timeToken" } else { $normalized }
    $parsed = Convert-ToDateOffset -RawValue $normalizedRaw -Source 'filename'
    if (-not $parsed.Valid) {
        return [pscustomobject]@{ Source = 'filename'; RawValue = $rawValue; Date = $null; Error = $parsed.Error; Token = $rawValue }
    }

    return [pscustomobject]@{ Source = 'filename'; RawValue = $rawValue; Date = $parsed.Date; Error = $null; Token = $rawValue }
}

function Get-DateEvidenceFromFolder {
    param([System.IO.FileInfo]$File)

    $folder = $File.Directory.Name
    $match = [regex]::Match($folder, '(?<date>20\d{2}[-_]?(?:0[1-9]|1[0-2])[-_]?(?:0[1-9]|[12]\d|3[01]))')
    if (-not $match.Success) {
        return $null
    }

    $normalized = $match.Groups['date'].Value -replace '_', '-'
    if ($normalized -notmatch '^\d{4}-\d{2}-\d{2}$') {
        $normalized = $normalized -replace '^(\d{4})(\d{2})(\d{2})$', '$1-$2-$3'
    }
    $parsed = Convert-ToDateOffset -RawValue $normalized -Source 'folder'
    if (-not $parsed.Valid) {
        return [pscustomobject]@{ Source = 'folder'; RawValue = $normalized; Date = $null; Error = $parsed.Error; Token = $normalized }
    }
    return [pscustomobject]@{ Source = 'folder'; RawValue = $normalized; Date = $parsed.Date; Error = $null; Token = $normalized }
}

function Get-DateEvidenceFromExif {
    param([System.IO.FileInfo]$File)

    if ($File.Extension.ToLowerInvariant() -notin @('.jpg', '.jpeg', '.tif', '.tiff')) {
        return @()
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $image = [Drawing.Image]::FromFile($File.FullName)
        try {
            foreach ($propertyId in @(0x9003, 0x9004)) {
                $property = $image.PropertyItems | Where-Object Id -eq $propertyId | Select-Object -First 1
                if ($null -ne $property) {
                    $rawValue = ([Text.Encoding]::ASCII.GetString($property.Value)).Trim([char]0).Trim()
                    $source = if ($propertyId -eq 0x9003) { 'exif-DateTimeOriginal' } else { 'exif-DateTimeDigitized' }
                    $parsed = Convert-ToDateOffset -RawValue $rawValue -Source $source
                    return [pscustomobject]@{ Source = $source; RawValue = $rawValue; Date = if ($parsed.Valid) { $parsed.Date } else { $null }; Error = $parsed.Error; Token = $null }
                }
            }
        }
        finally {
            $image.Dispose()
        }
    }
    catch {
        return [pscustomobject]@{ Source = 'exif'; RawValue = $null; Date = $null; Error = $_.Exception.Message; Token = $null }
    }

    return @()
}

function Get-FileDateReview {
    param([System.IO.FileInfo]$File)

    $creationUtc = $File.CreationTimeUtc
    $lastWriteUtc = $File.LastWriteTimeUtc
    $evidence = @()
    $evidence += @(Get-DateEvidenceFromExif -File $File)
    $evidence += @(Get-DateEvidenceFromName -File $File)
    $evidence = @($evidence | Where-Object { $null -ne $_ })
    if ($evidence.Count -eq 0) {
        $evidence += @(Get-DateEvidenceFromFolder -File $File)
    }
    $validEvidence = @($evidence | Where-Object { $null -ne $_ -and $null -ne $_.Date })
    $status = 'NoEvidence'
    $confidence = 'None'
    $proposedDate = $null
    $source = $null
    $rawValue = $null
    $token = $null
    $reason = 'No supported capture-date evidence was found.'

    $evidenceErrors = @($evidence | Where-Object { $null -ne $_ -and $null -ne $_.Error })
    if ($evidenceErrors.Count -gt 0) {
        $status = 'InvalidEvidence'
        $reason = (@($evidenceErrors | ForEach-Object Error) -join '; ')
    }
    elseif ($validEvidence.Count -gt 0) {
        $selected = $validEvidence | Sort-Object @{ Expression = { if ($_.Source -like 'exif-*') { 0 } else { 1 } } } | Select-Object -First 1
        $conflicting = @($validEvidence | Where-Object { $_.Date.UtcDateTime -ne $selected.Date.UtcDateTime })
        $proposedDate = $selected.Date
        $source = $selected.Source
        $rawValue = $selected.RawValue
        $token = $selected.Token
        $confidence = if ($selected.Source -like 'exif-*') { 'High' } elseif ($selected.Source -eq 'folder') { 'Low' } else { 'Medium' }
        if ($conflicting.Count -gt 0) {
            $status = 'Conflict'
            $reason = 'Multiple date sources disagree; no automatic change is allowed.'
        }
        elseif ($proposedDate.UtcDateTime -gt $FutureToleranceUtc.ToUniversalTime()) {
            $status = 'FutureDate'
            $reason = 'Proposed date exceeds the configured future tolerance.'
        }
        else {
            $status = 'Proposed'
            $reason = "Selected $source evidence over filesystem transfer timestamps."
        }
    }

    [ordered]@{
        path = $File.FullName
        size = $File.Length
        currentCreationTimeUtc = $creationUtc.ToString('o')
        currentLastWriteTimeUtc = $lastWriteUtc.ToString('o')
        proposedCaptureTimeUtc = if ($null -ne $proposedDate) { $proposedDate.UtcDateTime.ToString('o') } else { $null }
        source = $source
        rawValue = $rawValue
        parsedFilenameToken = $token
        confidence = $confidence
        status = $status
        reason = $reason
        policy = $Policy
    }
}

function Get-InputFiles {
    param([string[]]$Roots)

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            throw "Input path not found: $root"
        }
        $item = Get-Item -LiteralPath $root -Force
        if ($item -is [System.IO.FileInfo]) {
            $item
        }
        elseif ($Recurse) {
            Get-ChildItem -LiteralPath $root -File -Recurse -Force
        }
        else {
            Get-ChildItem -LiteralPath $root -File -Force
        }
    }
}

$resolvedManifestPath = [System.IO.Path]::GetFullPath($UndoManifestPath)
if ($Undo) {
    if (-not (Test-Path -LiteralPath $resolvedManifestPath)) {
        throw "Undo manifest not found: $UndoManifestPath"
    }

    $manifestEntries = @(Get-Content -LiteralPath $resolvedManifestPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($entry in ($manifestEntries | Select-Object -Last $manifestEntries.Count | Sort-Object appliedAtUtc -Descending)) {
        if (-not (Test-Path -LiteralPath $entry.path)) {
            throw "Undo refused; file is missing: $($entry.path)"
        }
        $current = Get-Item -LiteralPath $entry.path -Force
        if (-not (Test-FileTimeMatch -Actual $current.CreationTimeUtc -Expected $entry.afterCreationTimeUtc) -or -not (Test-FileTimeMatch -Actual $current.LastWriteTimeUtc -Expected $entry.afterLastWriteTimeUtc)) {
            throw "Undo refused; file changed since repair: $($entry.path)"
        }
        $current.CreationTimeUtc = [datetime]$entry.beforeCreationTimeUtc
        $current.LastWriteTimeUtc = [datetime]$entry.beforeLastWriteTimeUtc
    }
    Write-Host "Undo completed for $($manifestEntries.Count) file(s)."
    return
}

if (@($Path).Count -eq 0 -and [string]::IsNullOrWhiteSpace($ReviewPath)) {
    throw 'At least one input path or -ReviewPath is required unless -Undo is specified.'
}

$reviews = @()
if (-not [string]::IsNullOrWhiteSpace($ReviewPath)) {
    if (-not (Test-Path -LiteralPath $ReviewPath)) {
        throw "Review report not found: $ReviewPath"
    }
    $reviewDocument = Get-Content -LiteralPath $ReviewPath -Raw | ConvertFrom-Json
    $reviews = @($reviewDocument.items)
}
else {
    $files = @(Get-InputFiles -Roots $Path | Sort-Object FullName -Unique)
    foreach ($file in $files) {
        try {
            $reviews += Get-FileDateReview -File $file
        }
        catch {
            $reviews += [ordered]@{
                path = $file.FullName
                size = $file.Length
                currentCreationTimeUtc = $file.CreationTimeUtc.ToString('o')
                currentLastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                proposedCaptureTimeUtc = $null
                source = $null
                rawValue = $null
                parsedFilenameToken = $null
                confidence = 'None'
                status = 'Inaccessible'
                reason = "$($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
                policy = $Policy
            }
        }
    }
}

$decisions = @{}
if ($DecisionPath) {
    if (-not (Test-Path -LiteralPath $DecisionPath)) {
        throw "Decision file not found: $DecisionPath"
    }
    foreach ($decision in @(Get-Content -LiteralPath $DecisionPath -Raw | ConvertFrom-Json)) {
        $decisions[[System.IO.Path]::GetFullPath([string]$decision.path)] = $decision
    }
}

foreach ($review in $reviews) {
    $reviewPath = [System.IO.Path]::GetFullPath([string]$review.path)
    if ($decisions.ContainsKey($reviewPath)) {
        $decision = $decisions[$reviewPath]
        $review | Add-Member -NotePropertyName action -NotePropertyValue ([string]$decision.action) -Force
        switch ([string]$decision.action.ToLowerInvariant()) {
            'skip' { $review.status = 'Skipped'; $review.reason = 'Skipped by reviewer decision.' }
            'protect' { $review.status = 'Protected'; $review.reason = 'Protected by reviewer decision.' }
            'manual' {
                $manual = Convert-ToDateOffset -RawValue ([string]$decision.date) -Source 'manual'
                if (-not $manual.Valid) { throw "Invalid manual date for ${reviewPath}: $($manual.Error)" }
                $review.proposedCaptureTimeUtc = $manual.Date.UtcDateTime.ToString('o')
                $review.source = 'manual'
                $review.rawValue = [string]$decision.date
                $review.confidence = 'High'
                $review.status = 'Proposed'
                $review.reason = 'Manual reviewer override.'
            }
            'approve' { $review.reason = 'Approved by reviewer decision.' }
            default { throw "Unsupported review action '$($decision.action)' for $reviewPath. Use skip, protect, approve, or manual." }
        }
    }
}

$report = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    dryRun = (-not $Apply)
    policy = $Policy
    futureToleranceUtc = $FutureToleranceUtc.ToUniversalTime().ToString('o')
    items = @($reviews)
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8

if ($Apply) {
    $manifestDirectory = Split-Path -Path $resolvedManifestPath -Parent
    if ($manifestDirectory -and -not (Test-Path -LiteralPath $manifestDirectory)) {
        New-Item -Path $manifestDirectory -ItemType Directory -Force | Out-Null
    }
    $approved = @($ApprovePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
    foreach ($review in $reviews | Where-Object { $_.status -eq 'Proposed' -and ($_.confidence -eq 'High' -or $approved -contains $_.path -or (Get-PropertyValue -Value $_ -Name 'action') -eq 'approve' -or (Get-PropertyValue -Value $_ -Name 'action') -eq 'manual') }) {
        $current = Get-Item -LiteralPath $review.path -Force
        if ($current.Length -ne [long]$review.size -or -not (Test-FileTimeMatch -Actual $current.LastWriteTimeUtc -Expected $review.currentLastWriteTimeUtc)) {
            throw "Stale file refused: $($review.path)"
        }
        $beforeCreationTimeUtc = $current.CreationTimeUtc.ToString('o')
        $beforeLastWriteTimeUtc = $current.LastWriteTimeUtc.ToString('o')
        $current.CreationTimeUtc = [datetime]$review.proposedCaptureTimeUtc
        if ($Policy -eq 'CreationAndLastWriteTime') {
            $current.LastWriteTimeUtc = [datetime]$review.proposedCaptureTimeUtc
        }
        $manifestEntry = [ordered]@{
            path = $review.path
            beforeCreationTimeUtc = $beforeCreationTimeUtc
            beforeLastWriteTimeUtc = $beforeLastWriteTimeUtc
            afterCreationTimeUtc = $current.CreationTimeUtc.ToString('o')
            afterLastWriteTimeUtc = $current.LastWriteTimeUtc.ToString('o')
            appliedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            policy = $Policy
        }
        ($manifestEntry | ConvertTo-Json -Compress) | Add-Content -Path $resolvedManifestPath -Encoding UTF8
    }
}

[pscustomobject]@{
    outputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    itemCount = $reviews.Count
    proposedCount = @($reviews | Where-Object status -eq 'Proposed').Count
    applied = $Apply.IsPresent
}
