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

    $prettyFile = Join-Path $root '2024-06-07_pretty-undo.txt'
    'pretty undo' | Set-Content -Path $prettyFile -Encoding UTF8
    $prettyReview = Join-Path $root 'pretty-review.json'
    $prettyManifest = Join-Path $root 'pretty-undo.jsonl'
    $prettyDecision = Join-Path $root 'pretty-decision.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $prettyFile -OutputPath $prettyReview | Out-Null
    @([ordered]@{ path = [System.IO.Path]::GetFullPath($prettyFile); action = 'approve' }) | ConvertTo-Json | Set-Content -Path $prettyDecision -Encoding UTF8
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -ReviewPath $prettyReview -DecisionPath $prettyDecision -OutputPath (Join-Path $root 'pretty-apply.json') -Apply -UndoManifestPath $prettyManifest | Out-Null
    $prettyEntry = Get-Content -LiteralPath $prettyManifest | Where-Object { $_ } | Select-Object -First 1 | ConvertFrom-Json
    $prettyEntry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $prettyManifest -Encoding UTF8
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Undo -UndoManifestPath $prettyManifest | Out-Null

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

    function New-ExifJpeg {
        param(
            [string]$Path,
            [hashtable]$Tags
        )

        $bitmap = New-Object System.Drawing.Bitmap 1, 1
        $bitmap.SetPixel(0, 0, [System.Drawing.Color]::White)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $bitmap.Dispose()
        $image = [System.Drawing.Image]::FromFile($Path)
        try {
            foreach ($tagId in $Tags.Keys) {
                $property = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
                $property.Id = [int]$tagId
                $property.Type = 2
                $property.Value = [Text.Encoding]::ASCII.GetBytes("$($Tags[$tagId])`0")
                $property.Len = $property.Value.Length
                $image.SetPropertyItem($property)
            }
            $tempSave = "$Path.tmp.jpg"
            $image.Save($tempSave, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        finally {
            $image.Dispose()
        }
        Move-Item -LiteralPath $tempSave -Destination $Path -Force
    }

    $digitizedPath = Join-Path $root 'digitized-only.jpg'
    New-ExifJpeg -Path $digitizedPath -Tags @{ 0x9004 = '2021:04:05 06:07:08' }
    $digitizedReport = Join-Path $root 'digitized-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $digitizedPath -OutputPath $digitizedReport | Out-Null
    $digitizedItem = @((Get-Content -Path $digitizedReport -Raw | ConvertFrom-Json).items)[0]
    if ($digitizedItem.source -ne 'exif-DateTimeDigitized' -or $digitizedItem.status -ne 'Proposed' -or $digitizedItem.confidence -ne 'High') {
        throw "Digitized-date fallback failed. source=$($digitizedItem.source) status=$($digitizedItem.status)"
    }

    $bothExifPath = Join-Path $root 'both-exif.jpg'
    New-ExifJpeg -Path $bothExifPath -Tags @{ 0x9003 = '2021:04:05 06:07:08'; 0x9004 = '2020:01:01 00:00:00' }
    $bothExifReport = Join-Path $root 'both-exif-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $bothExifPath -OutputPath $bothExifReport | Out-Null
    $bothExifItem = @((Get-Content -Path $bothExifReport -Raw | ConvertFrom-Json).items)[0]
    if ($bothExifItem.status -ne 'Conflict') {
        throw "Original vs digitized EXIF mismatch was not a conflict. status=$($bothExifItem.status)"
    }

    $minuteTolerancePath = Join-Path $root '2022-01-02_030406.jpg'
    $localOffset = [TimeZoneInfo]::Local.GetUtcOffset([datetime]'2022-01-02T03:04:05').ToString('hh\:mm')
    if ([TimeZoneInfo]::Local.GetUtcOffset([datetime]'2022-01-02T03:04:05').Ticks -ge 0) { $localOffset = "+$localOffset" } else { $localOffset = "-$localOffset" }
    New-ExifJpeg -Path $minuteTolerancePath -Tags @{ 0x9003 = '2022:01:02 03:04:05'; 0x9011 = $localOffset }
    $minuteToleranceReport = Join-Path $root 'minute-tolerance-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $minuteTolerancePath -OutputPath $minuteToleranceReport | Out-Null
    $minuteToleranceItem = @((Get-Content -Path $minuteToleranceReport -Raw | ConvertFrom-Json).items)[0]
    if ($minuteToleranceItem.status -ne 'Proposed' -or $minuteToleranceItem.source -ne 'exif-DateTimeOriginal') {
        throw "Equivalent mixed-timezone evidence with a one-second difference was not proposed. status=$($minuteToleranceItem.status)"
    }

    $cameraFile = Join-Path $root 'PXL_20240102_153045.txt'
    'camera' | Set-Content -Path $cameraFile -Encoding UTF8
    $cameraReport = Join-Path $root 'camera-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $cameraFile -OutputPath $cameraReport | Out-Null
    $cameraItem = @((Get-Content -Path $cameraReport -Raw | ConvertFrom-Json).items)[0]
    if ($cameraItem.status -ne 'Proposed' -or $cameraItem.source -ne 'filename' -or $cameraItem.parsedFilenameToken -notlike '*20240102*') {
        throw "Camera-style filename was not parsed. status=$($cameraItem.status) token=$($cameraItem.parsedFilenameToken)"
    }

    $copyFile = Join-Path $root '2024-03-04_copied.txt'
    'copied' | Set-Content -Path $copyFile -Encoding UTF8
    $copyInfo = Get-Item -LiteralPath $copyFile
    $copyInfo.CreationTimeUtc = [datetime]'2010-01-01T00:00:00Z'
    $copyInfo.LastWriteTimeUtc = [datetime]'2010-01-01T00:00:00Z'
    $copyReport = Join-Path $root 'copy-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $copyFile -OutputPath $copyReport | Out-Null
    $copyDoc = Get-Content -Path $copyReport -Raw | ConvertFrom-Json
    $copyItem = @($copyDoc.items)[0]
    if ($copyItem.status -ne 'Proposed' -or $copyItem.source -ne 'filename') {
        throw 'Copied-file filesystem timestamps were used as capture time.'
    }
    if ($copyDoc.timezonePolicy -notlike '*transfer evidence only*') {
        throw 'Timezone policy was not recorded on the date-review report.'
    }

    $ambiguousFile = Join-Path $root 'scan-01-02-2024.txt'
    'ambiguous' | Set-Content -Path $ambiguousFile -Encoding UTF8
    $ambiguousReport = Join-Path $root 'ambiguous-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $ambiguousFile -OutputPath $ambiguousReport | Out-Null
    $ambiguousItem = @((Get-Content -Path $ambiguousReport -Raw | ConvertFrom-Json).items)[0]
    if ($ambiguousItem.status -ne 'InvalidEvidence' -or $ambiguousItem.reason -notlike '*Ambiguous*') {
        throw "Ambiguous month/day filename was not skipped. status=$($ambiguousItem.status) reason=$($ambiguousItem.reason)"
    }

    $impossibleFile = Join-Path $root '2024-02-30_shot.txt'
    'impossible' | Set-Content -Path $impossibleFile -Encoding UTF8
    $impossibleReport = Join-Path $root 'impossible-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $impossibleFile -OutputPath $impossibleReport | Out-Null
    $impossibleItem = @((Get-Content -Path $impossibleReport -Raw | ConvertFrom-Json).items)[0]
    if ($impossibleItem.status -ne 'InvalidEvidence' -or $impossibleItem.reason -notlike '*Impossible*') {
        throw "Impossible calendar date was not rejected. status=$($impossibleItem.status) reason=$($impossibleItem.reason)"
    }

    $tzFile = Join-Path $root '2024-06-07T150405+0200.txt'
    'tz' | Set-Content -Path $tzFile -Encoding UTF8
    $tzReport = Join-Path $root 'tz-review.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $tzFile -OutputPath $tzReport | Out-Null
    $tzItem = @((Get-Content -Path $tzReport -Raw | ConvertFrom-Json).items)[0]
    if ($tzItem.status -ne 'Proposed' -or $tzItem.timezoneKind -ne 'explicit-offset') {
        throw "Timezone offset filename was not parsed. status=$($tzItem.status) kind=$($tzItem.timezoneKind)"
    }
    $tzUtc = ([datetime]$tzItem.proposedCaptureTimeUtc).ToUniversalTime()
    if ($tzUtc.Hour -ne 13) {
        throw "Explicit +0200 offset was not converted to UTC. hour=$($tzUtc.Hour)"
    }

    $lockFile = Join-Path $root 'locked.txt'
    'locked' | Set-Content -Path $lockFile -Encoding UTF8
    $lockStream = [IO.File]::Open($lockFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockReport = Join-Path $root 'lock-review.json'
        & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $lockFile -OutputPath $lockReport | Out-Null
        $lockItem = @((Get-Content -Path $lockReport -Raw | ConvertFrom-Json).items)[0]
        if ($lockItem.status -ne 'Inaccessible') {
            throw "Locked file was not reported as inaccessible. status=$($lockItem.status)"
        }
    }
    finally {
        $lockStream.Dispose()
    }

    $batchPath = Join-Path $root 'camera-batch.jpg'
    New-ExifJpeg -Path $batchPath -Tags @{ 0x9003 = '2021:08:09 10:11:12' }
    $batchBefore = (Get-Item -LiteralPath $batchPath).CreationTimeUtc
    $batchDry = Join-Path $root 'batch-dry.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $batchPath -OutputPath $batchDry | Out-Null
    $batchDryItem = @((Get-Content -Path $batchDry -Raw | ConvertFrom-Json).items)[0]
    if ($batchDryItem.status -ne 'Proposed' -or $batchDryItem.confidence -ne 'High') {
        throw "High-confidence EXIF batch candidate was not proposed. status=$($batchDryItem.status)"
    }
    $batchNoSwitch = Join-Path $root 'batch-no-switch.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $batchPath -OutputPath $batchNoSwitch -Apply -UndoManifestPath (Join-Path $root 'batch-no-switch.jsonl') | Out-Null
    $batchAfterNoSwitch = (Get-Item -LiteralPath $batchPath).CreationTimeUtc
    if ($batchAfterNoSwitch.ToString('o') -ne $batchBefore.ToString('o')) {
        throw 'Apply without -ApproveHighConfidence changed a high-confidence file.'
    }
    $batchApply = Join-Path $root 'batch-apply.json'
    $batchManifest = Join-Path $root 'batch-undo.jsonl'
    $batchHashBefore = (Get-FileHash -LiteralPath $batchPath -Algorithm SHA256).Hash
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $batchPath -OutputPath $batchApply -Apply -ApproveHighConfidence -UndoManifestPath $batchManifest | Out-Null
    if (-not (Test-Path -LiteralPath $batchManifest)) {
        throw 'High-confidence batch approval did not write an undo manifest.'
    }
    $batchAfter = (Get-Item -LiteralPath $batchPath).CreationTimeUtc
    if ($batchAfter.ToString('o') -eq $batchBefore.ToString('o')) {
        throw 'High-confidence batch approval did not update CreationTime.'
    }
    $appliedItem = @((Get-Content -Path $batchApply -Raw | ConvertFrom-Json).items)[0]
    if (-not (Test-Path -LiteralPath $batchApply) -or
        [math]::Abs(($batchAfter - [datetime]$appliedItem.proposedCaptureTimeUtc).TotalSeconds) -gt 1) {
        throw "Apply did not leave CreationTime at the proposed date. actual=$($batchAfter.ToString('o')) proposed=$($appliedItem.proposedCaptureTimeUtc)"
    }
    $batchRescan = Join-Path $root 'batch-rescan.json'
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Path $batchPath -OutputPath $batchRescan | Out-Null
    $batchRescanItem = @((Get-Content -Path $batchRescan -Raw | ConvertFrom-Json).items)[0]
    if ($batchRescanItem.status -ne 'AlreadyApplied' -or $batchRescanItem.decisionSummary -notlike '*Already applied*') {
        throw "Rescan after apply did not mark the file already applied. status=$($batchRescanItem.status) summary=$($batchRescanItem.decisionSummary)"
    }
    & (Join-Path $PSScriptRoot '..\repair-dates.ps1') -Undo -UndoManifestPath $batchManifest | Out-Null
    $batchAfterUndo = Get-Item -LiteralPath $batchPath
    $batchHashAfterUndo = (Get-FileHash -LiteralPath $batchPath -Algorithm SHA256).Hash
    if ($batchHashAfterUndo -ne $batchHashBefore) {
        throw 'Undo changed file bytes.'
    }
    if ([math]::Abs(($batchAfterUndo.CreationTimeUtc - $batchBefore).TotalSeconds) -gt 1) {
        throw "Undo did not restore CreationTime. actual=$($batchAfterUndo.CreationTimeUtc.ToString('o')) expected=$($batchBefore.ToString('o'))"
    }

    Write-Host 'Phase 3 evidence tests passed.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
