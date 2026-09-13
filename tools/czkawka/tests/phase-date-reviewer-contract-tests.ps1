[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "qnap-date-reviewer-contract-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $root -ItemType Directory -Force | Out-Null
try {
    $file = Join-Path $root '2026-01-01_candidate.jpg'
    [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/AP/EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8Af//Z'))
    $reportPath = Join-Path $root 'date-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $root -OutputPath $reportPath | Out-Null
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if (-not $report.timezonePolicy) {
        throw 'Date review report is missing timezonePolicy for the WPF reviewer.'
    }
    $item = @($report.items) | Select-Object -First 1
    foreach ($name in @('rawValue', 'parsedFilenameToken', 'timezoneKind', 'timezoneOffset', 'reason', 'currentCreationTimeUtc', 'currentLastWriteTimeUtc', 'proposedCaptureTimeUtc', 'source', 'confidence', 'status', 'policy', 'evidenceComparison', 'decisionSummary')) {
        if (-not $item.PSObject.Properties.Name.Contains($name)) {
            throw "Date review item is missing reviewer field '$name'."
        }
    }
    if ($item.status -ne 'Proposed' -or $item.source -ne 'filename' -or $item.parsedFilenameToken -ne '2026-01-01') {
        throw "Filename evidence was not exposed for the reviewer. status=$($item.status) source=$($item.source) token=$($item.parsedFilenameToken)"
    }
    if ($item.decisionSummary -notlike '*Filename has a date*' -or $item.decisionSummary -notlike '*EXIF does not*') {
        throw "Decision summary did not highlight filename vs EXIF. summary=$($item.decisionSummary)"
    }
    $filenameRow = @($item.evidenceComparison | Where-Object { $_.label -eq 'Filename' }) | Select-Object -First 1
    try {
        $filenameUtc = [datetimeoffset]$filenameRow.utc
    }
    catch {
        throw "Filename evidence is missing a choosable UTC date. utc=$($filenameRow.utc)"
    }
    $filenameDate = $filenameUtc.Date.ToString('yyyy-MM-dd')
    $filenameUtcDate = $filenameUtc.UtcDateTime.ToString('yyyy-MM-dd')
    if ($filenameDate -ne '2026-01-01' -and $filenameUtcDate -ne '2026-01-01') {
        throw "Filename evidence UTC was not 2026-01-01. utc=$filenameUtc"
    }
    if ((Get-Content -LiteralPath $reportPath -Raw) -notmatch '"label":\s*"Filename"[\s\S]*?"utc":\s*"\d{4}-\d{2}-\d{2}T') {
        throw 'Filename evidence UTC was not written as an ISO-8601 string for the WPF reviewer.'
    }
    $labels = @($item.evidenceComparison | ForEach-Object label)
    if ($labels -notcontains 'EXIF' -or $labels -notcontains 'Filename' -or $labels -notcontains 'Filesystem') {
        throw "Evidence comparison is missing a required source row."
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
