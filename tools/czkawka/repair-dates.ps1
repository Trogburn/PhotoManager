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
    [switch]$ApproveHighConfidence,

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
    [string]$VerificationReportPath = '.\reports\dates\date-verification.json',

    [Parameter()]
    [datetime]$FutureToleranceUtc = (Get-Date).ToUniversalTime().AddDays(1)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EvidenceToleranceSeconds = 59
$script:TimezonePolicy = 'Naive capture timestamps are treated as unspecified local time. Explicit offsets and Zulu timestamps are converted to UTC. Capture evidence within 59 seconds is treated as equivalent; otherwise, disagreeing UTC instants are conflicts. Impossible and ambiguous dates are rejected. Filesystem CreationTime and LastWriteTime are transfer evidence only.'

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

function Read-JsonlEntries {
    param([string]$LiteralPath)

    $entries = @()
    $buffer = New-Object System.Text.StringBuilder
    foreach ($line in Get-Content -LiteralPath $LiteralPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        [void]$buffer.AppendLine($line)
        try {
            $parsed = $buffer.ToString() | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed) {
                $entries += $parsed
                [void]$buffer.Clear()
            }
        }
        catch {
            # Incomplete JSON object; keep buffering until the closing brace arrives.
        }
    }

    if ($buffer.Length -gt 0) {
        throw "Undo manifest contained incomplete JSON: $LiteralPath"
    }

    return @($entries)
}

function Test-FileTimeMatch {
    param(
        [datetime]$Actual,
        [object]$Expected
    )

    $expectedDate = if ($Expected -is [datetime]) { ([datetime]$Expected).ToUniversalTime() } else { [datetime]::Parse([string]$Expected).ToUniversalTime() }
    return [math]::Abs(($Actual.ToUniversalTime() - $expectedDate).TotalSeconds) -le 1
}

function Get-DateRepairEvidence {
    param([System.IO.FileInfo]$File)

    $decodeStatus = 'not-applicable'
    $decodeError = $null
    if ($File.Extension.ToLowerInvariant() -in @('.jpg', '.jpeg', '.tif', '.tiff', '.png', '.gif', '.bmp')) {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $image = [Drawing.Image]::FromFile($File.FullName)
            $image.Dispose()
            $decodeStatus = 'renderable'
        }
        catch {
            $decodeStatus = 'unrenderable'
            $decodeError = $_.Exception.Message
        }
    }
    [ordered]@{
        size = [long]$File.Length
        sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        creationTimeUtc = $File.CreationTimeUtc.ToString('o')
        lastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
        decodeStatus = $decodeStatus
        decodeError = $decodeError
    }
}

function Test-CalendarDate {
    param(
        [int]$Year,
        [int]$Month,
        [int]$Day
    )

    if ($Year -lt 1990 -or $Year -gt 2100 -or $Month -lt 1 -or $Month -gt 12 -or $Day -lt 1) {
        return $false
    }
    return $Day -le [datetime]::DaysInMonth($Year, $Month)
}

function Convert-ToDateOffset {
    param(
        [string]$RawValue,
        [string]$Source
    )

    $trimmed = $RawValue.Trim()
    if ($trimmed -match '^(?<month>0?[1-9]|1[0-2])[-/.](?<day>0?[1-9]|[12]\d|3[01])[-/.](?<year>\d{2}|\d{4})$') {
        return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Ambiguous $Source date (month/day/year vs day/month/year): $RawValue"; TimezoneKind = 'ambiguous'; Offset = $null }
    }

    $parsed = [datetimeoffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces
    $timezoneKind = 'unspecified-local'
    $offset = $null

    if ($trimmed -match '^(?<year>\d{4})[:\-](?<month>\d{2})[:\-](?<day>\d{2})(?:[ T](?<hour>\d{2})[:.]?(?<minute>\d{2})[:.]?(?<second>\d{2}))?(?<tz>Z|[+-]\d{2}:?\d{2})?$') {
        $year = [int]$Matches.year
        $month = [int]$Matches.month
        $day = [int]$Matches.day
        if (-not (Test-CalendarDate -Year $year -Month $month -Day $day)) {
            return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Impossible $Source date: $RawValue"; TimezoneKind = 'invalid'; Offset = $null }
        }
    }

    if ($trimmed -match 'Z$|[+-]\d{2}:?\d{2}$') {
        $timezoneKind = 'explicit-offset'
        $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeUniversal
        $normalized = $trimmed -replace '^(\d{4}):(\d{2}):(\d{2})', '$1-$2-$3' -replace '([+-]\d{2})(\d{2})$', '$1:$2'
        if (-not [datetimeoffset]::TryParse($normalized, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue"; TimezoneKind = 'invalid'; Offset = $null }
        }
        $offset = $parsed.ToString('zzz')
    }
    elseif ($trimmed -match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$') {
        $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeLocal
        if (-not [datetimeoffset]::TryParseExact($trimmed, 'yyyy:MM:dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue"; TimezoneKind = 'invalid'; Offset = $null }
        }
        $offset = $parsed.ToString('zzz')
    }
    elseif ($trimmed -match '^\d{4}-\d{2}-\d{2} \d{6}$') {
        $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeLocal
        if (-not [datetimeoffset]::TryParseExact($trimmed, 'yyyy-MM-dd HHmmss', [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue"; TimezoneKind = 'invalid'; Offset = $null }
        }
        $offset = $parsed.ToString('zzz')
    }
    elseif ($trimmed -match '^\d{4}-\d{2}-\d{2}$') {
        $styles = $styles -bor [Globalization.DateTimeStyles]::AssumeLocal
        if (-not [datetimeoffset]::TryParseExact($trimmed, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue"; TimezoneKind = 'invalid'; Offset = $null }
        }
        $offset = $parsed.ToString('zzz')
    }
    elseif (-not [datetimeoffset]::TryParse($trimmed, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [pscustomobject]@{ Valid = $false; Date = $null; Error = "Invalid $Source date: $RawValue"; TimezoneKind = 'invalid'; Offset = $null }
    }
    else {
        if ($parsed.Offset -eq [timespan]::Zero -and $trimmed -match 'Z$') {
            $timezoneKind = 'explicit-offset'
        }
        $offset = $parsed.ToString('zzz')
    }

    return [pscustomobject]@{ Valid = $true; Date = $parsed; Error = $null; TimezoneKind = $timezoneKind; Offset = $offset }
}

function New-DateEvidence {
    param(
        [string]$Source,
        [string]$RawValue,
        [object]$Date,
        [string]$Error,
        [string]$Token,
        [string]$TimezoneKind,
        [string]$Offset
    )

    return [pscustomobject]@{
        Source = $Source
        RawValue = $RawValue
        Date = $Date
        Error = $Error
        Token = $Token
        TimezoneKind = $TimezoneKind
        Offset = $Offset
    }
}

function Get-DateEvidenceFromName {
    param([System.IO.FileInfo]$File)

    if ($File.Extension.ToLowerInvariant() -in @('.xmp', '.aae', '.json', '.xml')) {
        return $null
    }

    $name = $File.BaseName
    $ambiguous = [regex]::Match($name, '(?<!\d)(?<token>(0?[1-9]|1[0-2])[-/.](0?[1-9]|[12]\d|3[01])[-/.](\d{2}|\d{4}))(?!\d)')
    if ($ambiguous.Success) {
        return New-DateEvidence -Source 'filename' -RawValue $ambiguous.Groups['token'].Value -Date $null -Error "Ambiguous filename date (month/day/year vs day/month/year): $($ambiguous.Groups['token'].Value)" -Token $ambiguous.Groups['token'].Value -TimezoneKind 'ambiguous' -Offset $null
    }

    $match = [regex]::Match($name, '(?<date>20\d{2}[-_]?(?<month>0[1-9]|1[0-2])[-_]?(?<day>0[1-9]|[12]\d|3[01]))(?:[T _-]?(?<time>[0-2]\d[0-5]\d[0-5]\d)(?<tz>Z|[+-][0-2]\d:?[0-5]\d)?)?')
    if (-not $match.Success) {
        $invalidToken = [regex]::Match($name, '20\d{2}[-_]?\d{2}[-_]?\d{2}')
        if ($invalidToken.Success) {
            return New-DateEvidence -Source 'filename' -RawValue $invalidToken.Value -Date $null -Error "Invalid or ambiguous filename date: $($invalidToken.Value)" -Token $invalidToken.Value -TimezoneKind 'invalid' -Offset $null
        }
        return $null
    }

    $year = [int]$match.Groups['date'].Value.Substring(0, 4)
    $month = [int]$match.Groups['month'].Value
    $day = [int]$match.Groups['day'].Value
    if (-not (Test-CalendarDate -Year $year -Month $month -Day $day)) {
        return New-DateEvidence -Source 'filename' -RawValue $match.Groups['date'].Value -Date $null -Error "Impossible filename date: $($match.Groups['date'].Value)" -Token $match.Value -TimezoneKind 'invalid' -Offset $null
    }

    $dateToken = $match.Groups['date'].Value
    $timeToken = $match.Groups['time'].Value
    $tzToken = $match.Groups['tz'].Value
    $rawValue = $match.Value
    $normalized = $dateToken -replace '_', '-'
    if ($normalized -notmatch '^\d{4}-\d{2}-\d{2}$') {
        $normalized = $normalized -replace '^(\d{4})(\d{2})(\d{2})$', '$1-$2-$3'
    }
    $normalizedRaw = $normalized
    if ($timeToken) {
        $normalizedRaw = "$normalized $($timeToken.Substring(0,2)):$($timeToken.Substring(2,2)):$($timeToken.Substring(4,2))"
        if ($tzToken) { $normalizedRaw += $tzToken }
    }
    $parsed = Convert-ToDateOffset -RawValue $normalizedRaw -Source 'filename'
    if (-not $parsed.Valid) {
        return New-DateEvidence -Source 'filename' -RawValue $rawValue -Date $null -Error $parsed.Error -Token $rawValue -TimezoneKind $parsed.TimezoneKind -Offset $parsed.Offset
    }

    return New-DateEvidence -Source 'filename' -RawValue $rawValue -Date $parsed.Date -Error $null -Token $rawValue -TimezoneKind $parsed.TimezoneKind -Offset $parsed.Offset
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
        return New-DateEvidence -Source 'folder' -RawValue $normalized -Date $null -Error $parsed.Error -Token $normalized -TimezoneKind $parsed.TimezoneKind -Offset $parsed.Offset
    }
    return New-DateEvidence -Source 'folder' -RawValue $normalized -Date $parsed.Date -Error $null -Token $normalized -TimezoneKind $parsed.TimezoneKind -Offset $parsed.Offset
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
            $offsetOriginal = $null
            $offsetDigitized = $null
            $offsetOriginalItem = $image.PropertyItems | Where-Object Id -eq 0x9011 | Select-Object -First 1
            $offsetDigitizedItem = $image.PropertyItems | Where-Object Id -eq 0x9012 | Select-Object -First 1
            if ($null -ne $offsetOriginalItem) {
                $offsetOriginal = ([Text.Encoding]::ASCII.GetString($offsetOriginalItem.Value)).Trim([char]0).Trim()
            }
            if ($null -ne $offsetDigitizedItem) {
                $offsetDigitized = ([Text.Encoding]::ASCII.GetString($offsetDigitizedItem.Value)).Trim([char]0).Trim()
            }

            $found = @()
            foreach ($propertyId in @(0x9003, 0x9004)) {
                $property = $image.PropertyItems | Where-Object Id -eq $propertyId | Select-Object -First 1
                if ($null -eq $property) { continue }
                $rawValue = ([Text.Encoding]::ASCII.GetString($property.Value)).Trim([char]0).Trim()
                $source = if ($propertyId -eq 0x9003) { 'exif-DateTimeOriginal' } else { 'exif-DateTimeDigitized' }
                $offset = if ($propertyId -eq 0x9003) { $offsetOriginal } else { $offsetDigitized }
                $parseValue = if ($offset -and $rawValue -notmatch 'Z$|[+-]\d{2}') { "$rawValue$offset" } else { $rawValue }
                $parsed = Convert-ToDateOffset -RawValue $parseValue -Source $source
                $found += New-DateEvidence -Source $source -RawValue $rawValue -Date $(if ($parsed.Valid) { $parsed.Date } else { $null }) -Error $parsed.Error -Token $null -TimezoneKind $parsed.TimezoneKind -Offset $parsed.Offset
            }
            return @($found)
        }
        finally {
            $image.Dispose()
        }
    }
    catch {
        return @(New-DateEvidence -Source 'exif' -RawValue $null -Date $null -Error $_.Exception.Message -Token $null -TimezoneKind 'invalid' -Offset $null)
    }
}

function Get-EvidenceRank {
    param([string]$Source)

    switch ($Source) {
        'exif-DateTimeOriginal' { 0 }
        'exif-DateTimeDigitized' { 1 }
        'filename' { 2 }
        'folder' { 3 }
        default { 4 }
    }
}

function Convert-EvidenceDateText {
    param($Evidence)

    if ($null -eq $Evidence) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Evidence.RawValue)) {
        return [string]$Evidence.RawValue
    }

    if ($null -ne $Evidence.Date) {
        return $Evidence.Date.UtcDateTime.ToString('yyyy-MM-dd HH:mm UTC')
    }

    return $null
}

function New-EvidenceComparisonRow {
    param(
        [string]$Label,
        [string]$State,
        [string]$Detail,
        [bool]$Selected,
        [string]$Utc
    )

    [ordered]@{
        label = $Label
        state = $State
        detail = $Detail
        selected = $Selected
        utc = if ([string]::IsNullOrWhiteSpace($Utc)) { $null } else { $Utc }
    }
}

function Get-EvidenceUtc {
    param($Evidence)

    if ($null -eq $Evidence -or $null -eq $Evidence.Date) {
        return $null
    }

    return $Evidence.Date.UtcDateTime.ToString('o')
}

function Get-EvidenceComparisonRows {
    param(
        $Evidence,
        [string]$SelectedSource,
        [datetime]$CreationUtc,
        [datetime]$LastWriteUtc
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $exifItems = @($Evidence | Where-Object { $_.Source -like 'exif*' })
    $exifDated = $exifItems | Where-Object { $null -ne $_.Date } | Select-Object -First 1
    $filename = $Evidence | Where-Object { $_.Source -eq 'filename' } | Select-Object -First 1
    $folder = $Evidence | Where-Object { $_.Source -eq 'folder' } | Select-Object -First 1

    if ($null -ne $exifDated) {
        [void]$rows.Add((New-EvidenceComparisonRow -Label 'EXIF' -State 'Has date' -Detail (Convert-EvidenceDateText $exifDated) -Selected ($SelectedSource -like 'exif*') -Utc (Get-EvidenceUtc $exifDated)))
    }
    elseif (@($exifItems | Where-Object { $_.Source -eq 'exif' -and -not [string]::IsNullOrWhiteSpace([string]$_.Error) }).Count -gt 0) {
        $err = $exifItems | Where-Object { $_.Source -eq 'exif' } | Select-Object -First 1
        [void]$rows.Add((New-EvidenceComparisonRow -Label 'EXIF' -State 'Unreadable' -Detail ([string]$err.Error) -Selected $false))
    }
    else {
        [void]$rows.Add((New-EvidenceComparisonRow -Label 'EXIF' -State 'Missing' -Detail 'No capture date' -Selected $false))
    }

    if ($null -ne $filename -and $null -ne $filename.Date) {
        [void]$rows.Add((New-EvidenceComparisonRow -Label 'Filename' -State 'Has date' -Detail (Convert-EvidenceDateText $filename) -Selected ($SelectedSource -eq 'filename') -Utc (Get-EvidenceUtc $filename)))
    }
    elseif ($null -ne $filename -and -not [string]::IsNullOrWhiteSpace([string]$filename.Error)) {
        [void]$rows.Add((New-EvidenceComparisonRow -Label 'Filename' -State 'Invalid' -Detail ([string]$filename.Error) -Selected $false))
    }
    else {
        [void]$rows.Add((New-EvidenceComparisonRow -Label 'Filename' -State 'Missing' -Detail 'No date in file name' -Selected $false))
    }

    if ($null -ne $folder) {
        if ($null -ne $folder.Date) {
            [void]$rows.Add((New-EvidenceComparisonRow -Label 'Folder' -State 'Has date' -Detail (Convert-EvidenceDateText $folder) -Selected ($SelectedSource -eq 'folder') -Utc (Get-EvidenceUtc $folder)))
        }
        else {
            [void]$rows.Add((New-EvidenceComparisonRow -Label 'Folder' -State 'Invalid' -Detail ([string]$folder.Error) -Selected $false))
        }
    }

    [void]$rows.Add((New-EvidenceComparisonRow -Label 'Filesystem' -State 'Transfer only' -Detail ("Created {0:yyyy-MM-dd}; modified {1:yyyy-MM-dd}" -f $CreationUtc, $LastWriteUtc) -Selected $false))
    return @($rows.ToArray())
}

function Get-DecisionSummaryFromRows {
    param(
        $Rows,
        [string]$Status,
        [string]$Reason
    )

    if ($Status -eq 'AlreadyApplied') {
        $selected = @($Rows | Where-Object { $_.selected }) | Select-Object -First 1
        if ($null -ne $selected -and $selected.state -eq 'Has date') {
            return "Already applied. $($selected.label) date ($($selected.detail)) already matches the file."
        }
        return $Reason
    }

    if ($Status -eq 'Conflict') {
        $dated = @($Rows | Where-Object { $_.state -eq 'Has date' -and $_.label -ne 'Filesystem' } | ForEach-Object { "$($_.label) $($_.detail)" })
        if ($dated.Count -gt 0) {
            return "Capture dates disagree: $($dated -join '; ')."
        }
        return $Reason
    }

    $selected = @($Rows | Where-Object { $_.selected }) | Select-Object -First 1
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $selected -and $selected.state -eq 'Has date') {
        $parts.Add("$($selected.label) has a date ($($selected.detail)).") | Out-Null
    }

    foreach ($row in @($Rows | Where-Object { $_.label -in @('EXIF', 'Filename', 'Folder') -and -not $_.selected })) {
        if ($row.state -eq 'Missing') {
            $parts.Add("$($row.label) does not.") | Out-Null
        }
        elseif ($row.state -eq 'Has date') {
            $parts.Add("$($row.label) agrees ($($row.detail)).") | Out-Null
        }
        elseif ($row.state -in @('Invalid', 'Unreadable')) {
            $parts.Add("$($row.label) is $($row.state.ToLowerInvariant()).") | Out-Null
        }
    }

    if ($parts.Count -eq 0) {
        return $Reason
    }

    return ($parts -join ' ')
}

function New-InaccessibleReview {
    param(
        [System.IO.FileInfo]$File,
        [string]$Reason
    )

    [ordered]@{
        path = $File.FullName
        size = $File.Length
        currentCreationTimeUtc = $File.CreationTimeUtc.ToString('o')
        currentLastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
        proposedCaptureTimeUtc = $null
        source = $null
        rawValue = $null
        parsedFilenameToken = $null
        timezoneKind = $null
        timezoneOffset = $null
        confidence = 'None'
        status = 'Inaccessible'
        reason = $Reason
        policy = $Policy
        evidenceComparison = @()
        decisionSummary = $Reason
    }
}

function Get-FileDateReview {
    param([System.IO.FileInfo]$File)

    try {
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $stream.Dispose()
    }
    catch {
        return New-InaccessibleReview -File $File -Reason "File is inaccessible: $($_.Exception.Message)"
    }

    $creationUtc = $File.CreationTimeUtc
    $lastWriteUtc = $File.LastWriteTimeUtc
    $evidence = @()
    $evidence += @(Get-DateEvidenceFromExif -File $File)
    $evidence += @(Get-DateEvidenceFromName -File $File)
    $evidence = @($evidence | Where-Object { $null -ne $_ })
    if (@($evidence | Where-Object { $_.Source -like 'exif-*' -and $null -ne $_.Date }).Count -eq 0 -and @($evidence | Where-Object { $_.Source -eq 'filename' -and $null -ne $_.Date }).Count -eq 0) {
        $evidence += @(Get-DateEvidenceFromFolder -File $File)
    }
    $evidence = @($evidence | Where-Object { $null -ne $_ })
    $validEvidence = @($evidence | Where-Object { $null -ne $_.Date })
    $status = 'NoEvidence'
    $confidence = 'None'
    $proposedDate = $null
    $source = $null
    $rawValue = $null
    $token = $null
    $timezoneKind = $null
    $timezoneOffset = $null
    $reason = 'No supported capture-date evidence was found. Filesystem CreationTime/LastWriteTime were treated as transfer evidence only.'

    $evidenceErrors = @($evidence | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Error) })
    if ($evidenceErrors.Count -gt 0) {
        $status = 'InvalidEvidence'
        $reason = (@($evidenceErrors | ForEach-Object Error) -join '; ')
    }
    elseif ($validEvidence.Count -gt 0) {
        $selected = $validEvidence | Sort-Object @{ Expression = { Get-EvidenceRank -Source $_.Source } } | Select-Object -First 1
        $conflicting = @($validEvidence | Where-Object {
            [math]::Abs(($_.Date.UtcDateTime - $selected.Date.UtcDateTime).TotalSeconds) -gt $script:EvidenceToleranceSeconds
        })
        $proposedDate = $selected.Date
        $source = $selected.Source
        $rawValue = $selected.RawValue
        $token = $selected.Token
        $timezoneKind = $selected.TimezoneKind
        $timezoneOffset = $selected.Offset
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
            $creationMatches = Test-FileTimeMatch -Actual $creationUtc -Expected $proposedDate.UtcDateTime
            $writeMatches = Test-FileTimeMatch -Actual $lastWriteUtc -Expected $proposedDate.UtcDateTime
            if ($creationMatches -and ($Policy -eq 'CreationTimeOnly' -or $writeMatches)) {
                $status = 'AlreadyApplied'
                $reason = if ($Policy -eq 'CreationTimeOnly') {
                    'Creation time already matches the proposed capture date.'
                }
                else {
                    'Creation and last-write times already match the proposed capture date.'
                }
            }
            else {
                $status = 'Proposed'
                $reason = "Selected $source evidence over filesystem transfer timestamps."
            }
        }
    }

    $comparison = @(Get-EvidenceComparisonRows -Evidence $evidence -SelectedSource ([string]$source) -CreationUtc $creationUtc -LastWriteUtc $lastWriteUtc)
    $decisionSummary = Get-DecisionSummaryFromRows -Rows $comparison -Status $status -Reason $reason

    [ordered]@{
        path = $File.FullName
        size = $File.Length
        currentCreationTimeUtc = $creationUtc.ToString('o')
        currentLastWriteTimeUtc = $lastWriteUtc.ToString('o')
        proposedCaptureTimeUtc = if ($null -ne $proposedDate) { $proposedDate.UtcDateTime.ToString('o') } else { $null }
        source = $source
        rawValue = $rawValue
        parsedFilenameToken = $token
        timezoneKind = $timezoneKind
        timezoneOffset = $timezoneOffset
        confidence = $confidence
        status = $status
        reason = $reason
        policy = $Policy
        evidenceComparison = $comparison
        decisionSummary = $decisionSummary
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

    $manifestEntries = @(Read-JsonlEntries -LiteralPath $resolvedManifestPath)
    foreach ($entry in ($manifestEntries | Select-Object -Last $manifestEntries.Count | Sort-Object appliedAtUtc -Descending)) {
        if (-not (Test-Path -LiteralPath $entry.path)) {
            throw "Undo refused; file is missing: $($entry.path)"
        }
        $current = Get-Item -LiteralPath $entry.path -Force
        if (-not (Test-FileTimeMatch -Actual $current.CreationTimeUtc -Expected $entry.afterCreationTimeUtc) -or -not (Test-FileTimeMatch -Actual $current.LastWriteTimeUtc -Expected $entry.afterLastWriteTimeUtc)) {
            throw "Undo refused; file changed since repair: $($entry.path)"
        }
        $preEvidence = Get-DateRepairEvidence -File $current
        $current.CreationTimeUtc = [datetime]$entry.beforeCreationTimeUtc
        $current.LastWriteTimeUtc = [datetime]$entry.beforeLastWriteTimeUtc
        $postFile = Get-Item -LiteralPath $entry.path -Force
        $postEvidence = Get-DateRepairEvidence -File $postFile
        $contentUnchanged = $preEvidence.size -eq $postEvidence.size -and
            $preEvidence.sha256 -eq $postEvidence.sha256 -and
            $preEvidence.decodeStatus -eq $postEvidence.decodeStatus
        $timestampsRestored = (Test-FileTimeMatch -Actual $postFile.CreationTimeUtc -Expected $entry.beforeCreationTimeUtc) -and
            (Test-FileTimeMatch -Actual $postFile.LastWriteTimeUtc -Expected $entry.beforeLastWriteTimeUtc)
        if (-not $contentUnchanged) {
            throw "Undo verification failed; file content changed: $($entry.path)"
        }
        if (-not $timestampsRestored) {
            throw "Undo verification failed; timestamps were not restored: $($entry.path)"
        }
    }
    Write-Host "Undo completed for $($manifestEntries.Count) file(s)."
    return
}

$inputPathCount = if ($null -eq $Path) { 0 } else { $Path.Count }
if ($inputPathCount -eq 0 -and [string]::IsNullOrWhiteSpace($ReviewPath)) {
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
                timezoneKind = $null
                timezoneOffset = $null
                confidence = 'None'
                status = 'Inaccessible'
                reason = "$($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
                policy = $Policy
                evidenceComparison = @()
                decisionSummary = "$($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
            }
        }
    }
}

function Read-DecisionEntries {
    param([string]$Path)

    $json = Get-Content -LiteralPath $Path -Raw
    # Windows PowerShell ConvertFrom-Json turns ISO-8601 strings into DateTime.
    # Stringifying those DateTime values drops Z and re-applies local offset, so a
    # reviewer-chosen UTC instant such as 09:04Z becomes 15:04Z in UTC-6.
    $protected = [regex]::Replace($json, '(?<=\"date\"\s*:\s*\")([^\"]+)', {
        param($match)
        'ISO|' + $match.Groups[1].Value
    })
    foreach ($decision in @($protected | ConvertFrom-Json)) {
        if ($null -ne $decision.PSObject.Properties['date'] -and [string]$decision.date -like 'ISO|*') {
            $decision.date = ([string]$decision.date).Substring(4)
        }
        $decision
    }
}

function Convert-ToUtcFileTime {
    param($Value)

    if ($Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).UtcDateTime
    }

    if ($Value -is [datetime]) {
        $dateTime = [datetime]$Value
        if ($dateTime.Kind -eq [DateTimeKind]::Utc) {
            return $dateTime
        }

        return $dateTime.ToUniversalTime()
    }

    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw "Invalid proposed capture timestamp: $Value"
    }

    return $parsed.UtcDateTime
}

$decisions = @{}
if ($DecisionPath) {
    if (-not (Test-Path -LiteralPath $DecisionPath)) {
        throw "Decision file not found: $DecisionPath"
    }
    foreach ($decision in @(Read-DecisionEntries -Path $DecisionPath)) {
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
    timezonePolicy = $script:TimezonePolicy
    futureToleranceUtc = $FutureToleranceUtc.ToUniversalTime().ToString('o')
    items = @($reviews)
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8

if ($Apply) {
    $verificationItems = @()
    $manifestDirectory = Split-Path -Path $resolvedManifestPath -Parent
    if ($manifestDirectory -and -not (Test-Path -LiteralPath $manifestDirectory)) {
        New-Item -Path $manifestDirectory -ItemType Directory -Force | Out-Null
    }
    $approved = @($ApprovePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
    foreach ($review in $reviews | Where-Object {
            $_.status -eq 'Proposed' -and (
                $approved -contains $_.path -or
                (Get-PropertyValue -Value $_ -Name 'action') -eq 'approve' -or
                (Get-PropertyValue -Value $_ -Name 'action') -eq 'manual' -or
                ($ApproveHighConfidence -and $_.confidence -eq 'High')
            )
        }) {
        $current = Get-Item -LiteralPath $review.path -Force
        if ($current.Length -ne [long]$review.size -or -not (Test-FileTimeMatch -Actual $current.LastWriteTimeUtc -Expected $review.currentLastWriteTimeUtc)) {
            throw "Stale file refused: $($review.path)"
        }
        $beforeCreationTimeUtc = $current.CreationTimeUtc.ToString('o')
        $beforeLastWriteTimeUtc = $current.LastWriteTimeUtc.ToString('o')
        $preEvidence = Get-DateRepairEvidence -File $current
        $proposedUtc = Convert-ToUtcFileTime -Value $review.proposedCaptureTimeUtc
        $current.CreationTimeUtc = $proposedUtc
        if ($Policy -eq 'CreationAndLastWriteTime') {
            $current.LastWriteTimeUtc = $proposedUtc
        }
        $manifestEntry = [ordered]@{
            path = $review.path
            beforeCreationTimeUtc = $beforeCreationTimeUtc
            beforeLastWriteTimeUtc = $beforeLastWriteTimeUtc
            afterCreationTimeUtc = $current.CreationTimeUtc.ToString('o')
            afterLastWriteTimeUtc = $current.LastWriteTimeUtc.ToString('o')
            appliedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            policy = $Policy
            preEvidence = $preEvidence
        }
        $postFile = Get-Item -LiteralPath $review.path -Force
        $postEvidence = Get-DateRepairEvidence -File $postFile
        $contentUnchanged = $preEvidence.size -eq $postEvidence.size -and $preEvidence.sha256 -eq $postEvidence.sha256 -and
            $preEvidence.decodeStatus -eq $postEvidence.decodeStatus
        if ($Policy -eq 'CreationTimeOnly') {
            $contentUnchanged = $contentUnchanged -and ($preEvidence.lastWriteTimeUtc -eq $postEvidence.lastWriteTimeUtc)
        }
        $timestampApplied = Test-FileTimeMatch -Actual $postFile.CreationTimeUtc -Expected $review.proposedCaptureTimeUtc
        if ($Policy -eq 'CreationAndLastWriteTime') {
            $timestampApplied = $timestampApplied -and (Test-FileTimeMatch -Actual $postFile.LastWriteTimeUtc -Expected $review.proposedCaptureTimeUtc)
        }
        $verified = $contentUnchanged -and $timestampApplied
        $manifestEntry.postEvidence = $postEvidence
        $manifestEntry.verificationPassed = $verified
        ($manifestEntry | ConvertTo-Json -Compress) | Add-Content -Path $resolvedManifestPath -Encoding UTF8
        $verificationItems += [pscustomobject]@{ path = $review.path; passed = $verified; preEvidence = $preEvidence; postEvidence = $postEvidence }
        if (-not $contentUnchanged) {
            throw "Date repair verification failed; file content changed: $($review.path)"
        }
        if (-not $timestampApplied) {
            throw "Date repair verification failed; creation time was not set to the proposed date: $($review.path)"
        }
    }
    $verificationDirectory = Split-Path -Path $VerificationReportPath -Parent
    if ($verificationDirectory -and -not (Test-Path -LiteralPath $verificationDirectory)) { New-Item -Path $verificationDirectory -ItemType Directory -Force | Out-Null }
    [pscustomobject]@{ generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); passed = (@($verificationItems | Where-Object { -not $_.passed }).Count -eq 0); items = $verificationItems } | ConvertTo-Json -Depth 10 | Set-Content -Path $VerificationReportPath -Encoding UTF8
}

$proposedCount = [int](($reviews | Where-Object { $_.status -eq 'Proposed' } | Measure-Object).Count)
[pscustomobject]@{
    outputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    itemCount = @($reviews).Count
    proposedCount = $proposedCount
    applied = $Apply.IsPresent
}
