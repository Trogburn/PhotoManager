[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$DecisionPath = '.\reports\review\decisions.json',

    [string]$HtmlReportPath = '.\reports\review\review.html',

    [string]$DateReviewPath,

    [switch]$ExportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Classified result file not found: $InputPath"
}
$data = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
if ($data.schemaVersion -ne 1 -or $data.source -ne 'classifier') {
    throw 'Review input must be a schema version 1 classifier document.'
}
$groups = @($data.groups)

function ConvertTo-HtmlText {
    param([object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Ensure-ParentDirectory {
    param([string]$FilePath)
    $parent = Split-Path -Path $FilePath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Save-Decisions {
    param([hashtable]$DecisionMap)
    Ensure-ParentDirectory -FilePath $DecisionPath
    @($DecisionMap.Values | Sort-Object groupId) | ConvertTo-Json -Depth 8 | Set-Content -Path $DecisionPath -Encoding UTF8
}

$decisionMap = @{}
if (Test-Path -LiteralPath $DecisionPath) {
    foreach ($decision in @(Get-Content -LiteralPath $DecisionPath -Raw | ConvertFrom-Json)) {
        $decisionMap[[string]$decision.groupId] = $decision
    }
}

$dateReviews = @{}
if ($DateReviewPath -and (Test-Path -LiteralPath $DateReviewPath)) {
    $dateDocument = Get-Content -LiteralPath $DateReviewPath -Raw | ConvertFrom-Json
    foreach ($dateItem in @($dateDocument.items)) { $dateReviews[[string]$dateItem.path] = $dateItem }
}

function Write-HtmlReport {
    Ensure-ParentDirectory -FilePath $HtmlReportPath
    $rows = foreach ($group in $groups) {
        $items = @($group.items)
        $paths = ($items | ForEach-Object { ConvertTo-HtmlText $_.path }) -join '<br />'
        "<tr><td>$(ConvertTo-HtmlText $group.groupId)</td><td>$(ConvertTo-HtmlText $group.confidenceTier)</td><td>$(ConvertTo-HtmlText (($group.labels -join ', ')))</td><td>$(ConvertTo-HtmlText $group.suggestedKeepPath)</td><td>$paths</td><td>$(ConvertTo-HtmlText $group.recommendationReason)</td></tr>"
    }
    $html = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Photo Review</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#202124}table{border-collapse:collapse;width:100%}th,td{border:1px solid #c7c7c7;padding:.5rem;text-align:left;vertical-align:top}th{background:#eef2f5}.tier{white-space:nowrap}</style></head>
<body><h1>Photo Review</h1><p>Advisory report. No filesystem actions are performed by this export.</p><table><thead><tr><th>Group</th><th>Confidence</th><th>Labels</th><th>Suggested keep</th><th>Items</th><th>Reason</th></tr></thead><tbody>$($rows -join "`n")</tbody></table></body>
</html>
"@
    Set-Content -Path $HtmlReportPath -Value $html -Encoding UTF8
}

Write-HtmlReport
if ($ExportOnly) {
    [pscustomobject]@{ htmlReportPath = (Resolve-Path -LiteralPath $HtmlReportPath).Path; groupCount = $groups.Count; exportOnly = $true }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'Photo Review'
$form.Width = 1280
$form.Height = 820
$form.StartPosition = 'CenterScreen'

$header = New-Object Windows.Forms.Label
$header.Dock = 'Top'
$header.Height = 58
$header.Padding = New-Object Windows.Forms.Padding(12, 10, 12, 8)
$header.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
$form.Controls.Add($header)

$details = New-Object Windows.Forms.TextBox
$details.Multiline = $true
$details.ReadOnly = $true
$details.ScrollBars = 'Vertical'
$details.Dock = 'Fill'
$details.Font = New-Object Drawing.Font('Consolas', 10)

$list = New-Object Windows.Forms.ListBox
$list.Dock = 'Fill'
$list.HorizontalScrollbar = $true
$list.Width = 420

$images = New-Object Windows.Forms.FlowLayoutPanel
$images.Dock = 'Fill'
$images.AutoScroll = $true
$images.WrapContents = $false
$images.FlowDirection = 'LeftToRight'

$right = New-Object Windows.Forms.TableLayoutPanel
$right.Dock = 'Fill'
$right.RowCount = 2
$right.ColumnCount = 1
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 58)))
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 42)))
$right.Controls.Add($images, 0, 0)
$right.Controls.Add($details, 0, 1)

$content = New-Object Windows.Forms.TableLayoutPanel
$content.Dock = 'Fill'
$content.ColumnCount = 2
$content.RowCount = 1
$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 420)))
$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
$content.Controls.Add($list, 0, 0)
$content.Controls.Add($right, 1, 0)
$form.Controls.Add($content)

$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Bottom'
$buttons.Height = 52
$buttons.Padding = New-Object Windows.Forms.Padding(8)
$buttons.WrapContents = $false
$form.Controls.Add($buttons)

function Add-ReviewButton {
    param([string]$Text, [scriptblock]$Action)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.Add_Click($Action)
    $buttons.Controls.Add($button)
    return $button
}

$currentIndex = 0
$currentItemIndex = 0
function Get-CurrentGroup { if ($groups.Count -gt 0) { return $groups[$currentIndex] }; return $null }
function Get-CurrentItem { $group = Get-CurrentGroup; if ($null -eq $group) { return $null }; $items = @($group.items); if ($items.Count -eq 0) { return $null }; return $items[[math]::Min($currentItemIndex, $items.Count - 1)] }

function Refresh-Review {
    $group = Get-CurrentGroup
    $list.Items.Clear()
    $images.Controls.Clear()
    if ($null -eq $group) {
        $header.Text = 'No review groups'
        $details.Text = 'The classifier produced no groups.'
        return
    }
    $header.Text = "Group $($currentIndex + 1) of $($groups.Count) | $($group.confidenceTier) | $($group.labels -join ', ')"
    foreach ($item in @($group.items)) { [void]$list.Items.Add([string]$item.path) }
    $list.SelectedIndex = [math]::Min($currentItemIndex, [math]::Max(0, $list.Items.Count - 1))
    $details.Text = "Confidence: $($group.confidenceTier)`r`nLabels: $($group.labels -join ', ')`r`nSuggested keep: $($group.suggestedKeepPath)`r`nReason: $($group.recommendationReason)`r`n`r`n" + (($group.items | ForEach-Object { $date = if ($dateReviews.ContainsKey([string]$_.path)) { $dateReviews[[string]$_.path].proposedCaptureTimeUtc } else { 'n/a' }; "$($_.path)`r`n  Size: $($_.size)  Dimensions: $($_.width)x$($_.height)  Difference: $($_.perceptualDifference)  Proposed date: $date  Protected: $($_.protected)" }) -join "`r`n")
    foreach ($item in @($group.items)) {
        $panel = New-Object Windows.Forms.Panel
        $panel.Width = 360
        $panel.Height = 300
        $picture = New-Object Windows.Forms.PictureBox
        $picture.Width = 350
        $picture.Height = 250
        $picture.SizeMode = 'Zoom'
        $picture.Top = 0
        $picture.Left = 0
        try {
            if (Test-Path -LiteralPath $item.path) { $picture.Image = [Drawing.Image]::FromFile($item.path) }
            else { throw 'File is unavailable.' }
        }
        catch {
            $fallback = New-Object Windows.Forms.Label
            $fallback.Text = "Preview unavailable`r`n$($item.path)"
            $fallback.AutoSize = $false
            $fallback.Width = 350
            $fallback.Height = 250
            $fallback.TextAlign = 'MiddleCenter'
            $panel.Controls.Add($fallback)
        }
        if ($null -ne $picture.Image) { $panel.Controls.Add($picture) }
        $caption = New-Object Windows.Forms.Label
        $caption.Text = [IO.Path]::GetFileName($item.path)
        $caption.Top = 255
        $caption.Width = 350
        $caption.Height = 40
        $panel.Controls.Add($caption)
        $images.Controls.Add($panel)
    }
}

$list.Add_SelectedIndexChanged({ $currentItemIndex = [math]::Max(0, $list.SelectedIndex); Refresh-Review })

Add-ReviewButton -Text 'Previous' -Action { if ($currentIndex -gt 0) { $currentIndex--; $currentItemIndex = 0; Refresh-Review } } | Out-Null
Add-ReviewButton -Text 'Next' -Action { if ($currentIndex -lt $groups.Count - 1) { $currentIndex++; $currentItemIndex = 0; Refresh-Review } } | Out-Null
Add-ReviewButton -Text 'Keep suggestion' -Action {
    $group = Get-CurrentGroup
    if ($null -ne $group) { $decisionMap[$group.groupId] = [pscustomobject]@{ groupId = $group.groupId; action = 'keep'; keepPath = $group.suggestedKeepPath; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save-Decisions $decisionMap }
} | Out-Null
Add-ReviewButton -Text 'Choose selected keep' -Action {
    $group = Get-CurrentGroup
    $item = Get-CurrentItem
    if ($null -ne $group -and $null -ne $item) { $decisionMap[$group.groupId] = [pscustomobject]@{ groupId = $group.groupId; action = 'keep'; keepPath = $item.path; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save-Decisions $decisionMap }
} | Out-Null
Add-ReviewButton -Text 'Queue quarantine' -Action {
    $group = Get-CurrentGroup
    if ($null -ne $group -and [Windows.Forms.MessageBox]::Show('Record a quarantine request for this group? No files will be moved in Phase 5.', 'Confirm request', 'YesNo', 'Warning') -eq 'Yes') {
        $decisionMap[$group.groupId] = [pscustomobject]@{ groupId = $group.groupId; action = 'quarantine-requested'; keepPath = $group.suggestedKeepPath; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save-Decisions $decisionMap
    }
} | Out-Null
Add-ReviewButton -Text 'Queue selected quarantine' -Action {
    $group = Get-CurrentGroup
    $item = Get-CurrentItem
    if ($null -ne $group -and $null -ne $item -and [Windows.Forms.MessageBox]::Show('Record a quarantine request for the selected item? No files will be moved in Phase 5.', 'Confirm request', 'YesNo', 'Warning') -eq 'Yes') {
        $decisionMap["$($group.groupId):$($item.path)"] = [pscustomobject]@{ groupId = $group.groupId; path = $item.path; action = 'quarantine-requested'; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save-Decisions $decisionMap
    }
} | Out-Null
Add-ReviewButton -Text 'Skip / defer' -Action {
    $group = Get-CurrentGroup
    if ($null -ne $group) { $decisionMap[$group.groupId] = [pscustomobject]@{ groupId = $group.groupId; action = 'defer'; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save-Decisions $decisionMap }
} | Out-Null
Add-ReviewButton -Text 'Protect selected' -Action {
    $item = Get-CurrentItem
    if ($null -ne $item) { $decisionMap["$($item.path)"] = [pscustomobject]@{ path = $item.path; action = 'protect'; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; Save-Decisions $decisionMap }
} | Out-Null
Add-ReviewButton -Text 'Open file' -Action { $item = Get-CurrentItem; if ($null -ne $item) { Start-Process -FilePath $item.path } } | Out-Null
Add-ReviewButton -Text 'Open folder' -Action { $item = Get-CurrentItem; if ($null -ne $item) { Start-Process explorer.exe -ArgumentList "/select,`"$($item.path)`"" } } | Out-Null

Refresh-Review
[void]$form.ShowDialog()
