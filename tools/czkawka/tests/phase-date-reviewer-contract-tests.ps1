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
    foreach ($name in @('rawValue', 'parsedFilenameToken', 'timezoneKind', 'timezoneOffset', 'reason', 'currentCreationTimeUtc', 'currentLastWriteTimeUtc', 'proposedCaptureTimeUtc', 'source', 'confidence', 'status', 'policy')) {
        if (-not $item.PSObject.Properties.Name.Contains($name)) {
            throw "Date review item is missing reviewer field '$name'."
        }
    }
    if ($item.status -ne 'Proposed' -or $item.source -ne 'filename' -or $item.parsedFilenameToken -ne '2026-01-01') {
        throw "Filename evidence was not exposed for the reviewer. status=$($item.status) source=$($item.source) token=$($item.parsedFilenameToken)"
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
