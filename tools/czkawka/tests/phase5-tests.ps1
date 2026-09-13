[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "qnap-phase5-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $root -ItemType Directory -Force | Out-Null
try {
    $fixture = Join-Path $PSScriptRoot 'fixtures\phase5-review.json'
    $fixtureBefore = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
    $input = Join-Path $root 'classified.json'
    $decisions = Join-Path $root 'decisions.json'
    $html = Join-Path $root 'review.html'
    $json = Join-Path $root 'review.json'
    $dateReview = Join-Path $root 'date-review.json'
    $document = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json

    # Exercise a missing/inaccessible UNC-shaped item and a persisted deferred group.
    $document.groups[1].items[0] | Add-Member -NotePropertyName accessState -NotePropertyValue 'inaccessible' -Force
    $document.groups[1].items[0] | Add-Member -NotePropertyName error -NotePropertyValue 'Fixture access denied.' -Force
    $document.groups[1].items[0] | Add-Member -NotePropertyName modifiedTime -NotePropertyValue '2026-09-09T12:00:00Z' -Force
    $document.groups[2].items[0] | Add-Member -NotePropertyName accessState -NotePropertyValue 'unavailable' -Force
    $document | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $input -Encoding UTF8
    @([pscustomobject]@{ groupId = 'review-0002'; action = 'defer'; decidedAtUtc = '2026-09-10T00:00:00Z' }) |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $decisions -Encoding UTF8
    [pscustomobject]@{
        items = @([pscustomobject]@{
            path = '\\server\photos\Reference\original.jpg'
            proposedCaptureTimeUtc = '2024-01-01T00:00:00Z'
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dateReview -Encoding UTF8

    $review = Join-Path $PSScriptRoot '..\review.ps1'
    & $review -InputPath $input -DecisionPath $decisions -HtmlReportPath $html -JsonReportPath $json -DateReviewPath $dateReview -ExportOnly | Out-Null
    if (-not (Test-Path -LiteralPath $html) -or -not (Test-Path -LiteralPath $json)) {
        throw 'Reviewer did not produce both static archive formats.'
    }
    $htmlText = Get-Content -LiteralPath $html -Raw
    $archive = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
    foreach ($term in @('search', 'filename', 'Dimensions', 'Size', 'Modified', 'Proposed date', 'Complete evidence', 'filterRows')) {
        if ($htmlText -notmatch [regex]::Escape($term)) { throw "HTML archive omitted '$term'." }
    }
    if (-not $archive.search.supported -or @($archive.search.fields).Count -lt 8) {
        throw 'JSON archive did not describe searchable fields.'
    }
    $inaccessible = @($archive.groups.items | Where-Object { $_.accessState -eq 'inaccessible' })[0]
    if ($null -eq $inaccessible -or $inaccessible.error -ne 'Fixture access denied.') {
        throw 'Inaccessible evidence was not retained in the JSON archive.'
    }
    $deferredGroup = @($archive.groups | Where-Object groupId -eq 'review-0002')[0]
    if ($null -eq $deferredGroup -or $deferredGroup.searchText -notmatch 'review-0002') {
        throw 'Deferred group was not retained as a searchable archive group.'
    }
    $uncItem = @($archive.groups.items | Where-Object path -eq '\\server\photos\Reference\original.jpg')[0]
    if ($null -eq $uncItem -or $uncItem.filename -eq '') { throw 'UNC-shaped path did not round-trip with filename.' }
    $proposedDate = [datetimeoffset]::Parse([string]$uncItem.proposedDate).UtcDateTime
    if ($proposedDate.Year -ne 2024 -or $proposedDate.Month -ne 1 -or $proposedDate.Day -ne 1) { throw "Date proposal was not included in the archive: $($uncItem | ConvertTo-Json -Compress)" }
    if ((Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -ne $fixtureBefore) {
        throw 'Reviewer changed the source fixture.'
    }
    Write-Host 'Phase 5 reviewer tests passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
