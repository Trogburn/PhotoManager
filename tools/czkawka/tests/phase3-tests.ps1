[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "qnap-phase3-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $root -ItemType Directory -Force | Out-Null
try {
    Add-Type -AssemblyName System.Drawing
    $folder = Join-Path $root '2023-11-05'
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    $folderFile = Join-Path $folder 'camera-copy.txt'
    'folder evidence' | Set-Content -Path $folderFile -Encoding UTF8

    $futureFile = Join-Path $root '2099-01-01_future.txt'
    'future' | Set-Content -Path $futureFile -Encoding UTF8

    $invalidFile = Join-Path $root '2024-13-40_invalid.txt'
    'invalid' | Set-Content -Path $invalidFile -Encoding UTF8

    $sidecar = Join-Path $root '2024-01-01_notes.xmp'
    'sidecar' | Set-Content -Path $sidecar -Encoding UTF8

    $bitmapPath = Join-Path $root '2023-02-03_exif.jpg'
    $bitmap = New-Object System.Drawing.Bitmap 1, 1
    $bitmap.SetPixel(0, 0, [System.Drawing.Color]::White)
    $bitmap.Save($bitmapPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bitmap.Dispose()
    $image = [System.Drawing.Image]::FromFile($bitmapPath)
    try {
        $property = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
        $property.Id = 0x9003
        $property.Type = 2
        $property.Value = [Text.Encoding]::ASCII.GetBytes("2022:01:02 03:04:05`0")
        $property.Len = $property.Value.Length
        $image.SetPropertyItem($property)
        $exifPath = Join-Path $root '2023-02-03_exif-tag.jpg'
        $image.Save($exifPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally {
        $image.Dispose()
    }

    $reportPath = Join-Path $root 'review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $root -Recurse -OutputPath $reportPath | Out-Null
    $report = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
    $items = @($report.items)

    $folderItem = $items | Where-Object path -eq ([System.IO.Path]::GetFullPath($folderFile))
    if ($folderItem.status -ne 'Proposed' -or $folderItem.source -ne 'folder' -or $folderItem.confidence -ne 'Low') {
        throw 'Folder date was not treated as low-confidence evidence.'
    }

    $futureItem = $items | Where-Object path -eq ([System.IO.Path]::GetFullPath($futureFile))
    if ($futureItem.status -ne 'FutureDate') {
        throw 'Future filename date was not rejected.'
    }

    $invalidItem = $items | Where-Object path -eq ([System.IO.Path]::GetFullPath($invalidFile))
    if ($invalidItem.status -ne 'InvalidEvidence' -or $invalidItem.reason -notlike '*Invalid or ambiguous*') {
        throw 'Invalid filename date was not reported clearly.'
    }

    $sidecarItem = $items | Where-Object path -eq ([System.IO.Path]::GetFullPath($sidecar))
    if ($sidecarItem.status -ne 'NoEvidence') {
        throw 'Sidecar metadata was unexpectedly treated as capture-date evidence.'
    }

    $exifPath = Join-Path $root '2023-02-03_exif-tag.jpg'
    $exifReportPath = Join-Path $root 'exif-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $exifPath -OutputPath $exifReportPath | Out-Null
    $exifItem = @((Get-Content -Path $exifReportPath -Raw | ConvertFrom-Json).items)[0]
    if ($exifItem.source -ne 'exif-DateTimeOriginal' -or $exifItem.status -ne 'Conflict') {
        throw 'EXIF precedence or filename conflict handling failed.'
    }

    $savedReviewFile = Join-Path $root '2024-06-07_saved-review.txt'
    'saved review' | Set-Content -Path $savedReviewFile -Encoding UTF8
    $savedReview = Join-Path $root 'saved-review.json'
    $savedManifest = Join-Path $root 'saved-review-undo.jsonl'
    $decisionPath = Join-Path $root 'decisions.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $savedReviewFile -OutputPath $savedReview | Out-Null
    @([ordered]@{ path = [System.IO.Path]::GetFullPath($savedReviewFile); action = 'approve' }) | ConvertTo-Json | Set-Content -Path $decisionPath -Encoding UTF8
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -ReviewPath $savedReview -DecisionPath $decisionPath -OutputPath (Join-Path $root 'saved-apply.json') -Apply -UndoManifestPath $savedManifest | Out-Null
    if (-not (Test-Path -LiteralPath $savedManifest)) {
        throw 'Saved review approval did not apply or create an undo manifest.'
    }
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Undo -UndoManifestPath $savedManifest | Out-Null

    $staleFile = Join-Path $root '2024-07-08_stale.txt'
    'before' | Set-Content -Path $staleFile -Encoding UTF8
    $staleReview = Join-Path $root 'stale-review.json'
    $staleDecision = Join-Path $root 'stale-decision.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $staleFile -OutputPath $staleReview | Out-Null
    @([ordered]@{ path = [System.IO.Path]::GetFullPath($staleFile); action = 'approve' }) | ConvertTo-Json | Set-Content -Path $staleDecision -Encoding UTF8
    'after review' | Set-Content -Path $staleFile -Encoding UTF8
    try {
        & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -ReviewPath $staleReview -DecisionPath $staleDecision -OutputPath (Join-Path $root 'stale-apply.json') -Apply -UndoManifestPath (Join-Path $root 'stale-undo.jsonl') 2>&1 | Out-Null
        throw 'Stale saved review unexpectedly applied.'
    }
    catch {
        if ($_.Exception.Message -notlike '*Stale file refused*') {
            throw "Unexpected stale review error: $($_.Exception.Message)"
        }
    }

    Write-Host 'Phase 3 evidence tests passed.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
