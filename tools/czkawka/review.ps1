[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$DecisionPath = '.\reports\review\decisions.json',

    [string]$HtmlReportPath = '.\reports\review\review.html',

    [string]$JsonReportPath = '.\reports\review\review.json',

    [string]$DateReviewPath,

    [switch]$ExportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-hash.ps1')

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

function Get-ReviewValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.PSObject.Properties[$Name].Value
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
    Update-ReviewQueue
}

function Get-ReviewDecisionKey {
    param([object]$Decision)

    $groupId = [string](Get-ReviewValue -Object $Decision -Name 'groupId')
    $path = [string](Get-ReviewValue -Object $Decision -Name 'path')
    if (-not [string]::IsNullOrWhiteSpace($groupId) -and -not [string]::IsNullOrWhiteSpace($path)) { return "item:$groupId|$path" }
    if (-not [string]::IsNullOrWhiteSpace($groupId)) { return "group:$groupId" }
    return "path:$path"
}

function Get-DecisionSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot queue a missing file for quarantine: $Path"
    }
    return Get-Sha256Hex -LiteralPath $Path
}

function Get-DateProposal {
    param([object]$Item)
    if ($dateReviews.ContainsKey([string]$Item.path)) {
        return $dateReviews[[string]$Item.path]
    }
    return $null
}

$decisionMap = @{}
if (Test-Path -LiteralPath $DecisionPath) {
    foreach ($decision in @(Get-Content -LiteralPath $DecisionPath -Raw | ConvertFrom-Json)) {
        $decisionKey = Get-ReviewDecisionKey -Decision $decision
        if ($decisionKey -ne 'path:') { $decisionMap[$decisionKey] = $decision }
    }
}
$script:protectedOverrides = @{}
foreach ($savedDecision in $decisionMap.Values | Where-Object { $_.PSObject.Properties['path'] -and $_.PSObject.Properties['protected'] }) {
    $script:protectedOverrides[[string]$savedDecision.path] = [bool]$savedDecision.protected
}

$dateReviews = @{}
if ($DateReviewPath -and (Test-Path -LiteralPath $DateReviewPath)) {
    $dateDocument = Get-Content -LiteralPath $DateReviewPath -Raw | ConvertFrom-Json
    foreach ($dateItem in @($dateDocument.items)) { $dateReviews[[string]$dateItem.path] = $dateItem }
}

function Get-ReviewedGroupIds {
    $reviewed = @{}
    foreach ($decision in $decisionMap.Values) {
        $groupId = [string](Get-ReviewValue -Object $decision -Name 'groupId')
        if (-not [string]::IsNullOrWhiteSpace($groupId)) {
            $reviewed[$groupId] = $true
            continue
        }
        $path = [string](Get-ReviewValue -Object $decision -Name 'path')
        foreach ($group in $script:allGroups) {
            if (@($group.items | Where-Object { $_.path -eq $path }).Count -gt 0) { $reviewed[[string]$group.groupId] = $true }
        }
    }
    return $reviewed
}

function Update-ReviewQueue {
    param([string]$PreferredGroupId)

    $previousIndex = $script:currentIndex
    $reviewed = Get-ReviewedGroupIds
    $unreviewed = @($script:allGroups | Where-Object { -not $reviewed.ContainsKey([string]$_.groupId) })
    $reviewedGroups = @($script:allGroups | Where-Object { $reviewed.ContainsKey([string]$_.groupId) })
    $script:groups = @($(if ($script:showReviewed) { @($unreviewed + $reviewedGroups) } else { $unreviewed }))
    $script:currentIndex = [math]::Min($previousIndex, [math]::Max(0, $script:groups.Count - 1))
    if ($PreferredGroupId) {
        for ($index = 0; $index -lt $script:groups.Count; $index++) {
            if ($script:groups[$index].groupId -eq $PreferredGroupId) { $script:currentIndex = $index; break }
        }
    }
    $script:currentItemIndex = 0
    $script:remainingGroupCount = $unreviewed.Count
}

function Write-HtmlReport {
    Ensure-ParentDirectory -FilePath $HtmlReportPath
    $rows = foreach ($group in $groups) {
        foreach ($item in @($group.items)) {
            $date = Get-DateProposal -Item $item
            $evidence = (@(Get-ReviewValue -Object $item -Name 'evidence') | ConvertTo-Json -Depth 12 -Compress)
            $modifiedTime = Get-ReviewValue -Object $item -Name 'modifiedTime'
            $accessState = Get-ReviewValue -Object $item -Name 'accessState'
            $error = Get-ReviewValue -Object $item -Name 'error'
            $warning = Get-ReviewValue -Object $item -Name 'warning'
            $proposedDate = if ($null -ne $date) { $date.proposedCaptureTimeUtc } else { $null }
            $searchText = @(
                $group.groupId, $group.confidenceTier, ($group.labels -join ' '),
                $group.suggestedKeepPath, $group.recommendationReason, $item.path,
                ([IO.Path]::GetFileName($item.path)), $item.width, $item.height,
                $item.size, $modifiedTime, $accessState, $error,
                $warning, $proposedDate, $evidence
            ) -join ' '
            $isSuggested = $item.path -eq $group.suggestedKeepPath
            "<tr data-search=""$(ConvertTo-HtmlText $searchText)""><td>$(ConvertTo-HtmlText $group.groupId)</td><td>$(ConvertTo-HtmlText $group.confidenceTier)</td><td>$(ConvertTo-HtmlText (($group.labels -join ', ')))</td><td>$(ConvertTo-HtmlText $group.recommendationReason)</td><td>$(ConvertTo-HtmlText $item.path)</td><td>$(ConvertTo-HtmlText ([IO.Path]::GetFileName($item.path)))</td><td>$(ConvertTo-HtmlText (""$($item.width)x$($item.height)""))</td><td>$(ConvertTo-HtmlText $item.size)</td><td>$(ConvertTo-HtmlText $modifiedTime)</td><td>$(ConvertTo-HtmlText $proposedDate)</td><td>$(if ($isSuggested) { 'yes' } else { 'no' })</td><td>$(ConvertTo-HtmlText $accessState)</td><td>$(ConvertTo-HtmlText $evidence)</td></tr>"
        }
    }
    $html = @"
<!doctype html>
<head><meta charset="utf-8"><title>Photo Review</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;color:#202124}input{font-size:1rem;padding:.5rem;width:28rem}table{border-collapse:collapse;width:100%;margin-top:1rem}th,td{border:1px solid #c7c7c7;padding:.5rem;text-align:left;vertical-align:top;max-width:28rem;overflow-wrap:anywhere}th{background:#eef2f5;position:sticky;top:0}.tier{white-space:nowrap}.notice{background:#fff8dc;padding:.75rem}</style></head>
<body><h1>Photo Review</h1><p class="notice">Advisory archive. No filesystem actions are performed by this export.</p><label for="search">Search groups, paths, filenames, evidence, dates, or access state:</label><br /><input id="search" type="search" placeholder="Type to filter..." oninput="filterRows()" /><span id="count"></span><table><thead><tr><th>Group</th><th>Confidence</th><th>Labels</th><th>Reason</th><th>Path</th><th>Filename</th><th>Dimensions</th><th>Size</th><th>Modified</th><th>Proposed date</th><th>Suggested keep</th><th>Access</th><th>Complete evidence</th></tr></thead><tbody>$($rows -join "`n")</tbody></table><script>function filterRows(){const q=document.getElementById('search').value.toLowerCase();let n=0;document.querySelectorAll('tbody tr').forEach(r=>{const show=!q||r.dataset.search.toLowerCase().includes(q);r.hidden=!show;if(show)n++;});document.getElementById('count').textContent=' '+n+' matching item(s)';}filterRows();</script></body>
</html>
"@
    Set-Content -Path $HtmlReportPath -Value $html -Encoding UTF8
}

function Write-JsonReport {
    Ensure-ParentDirectory -FilePath $JsonReportPath
    $archiveGroups = foreach ($group in $groups) {
        [ordered]@{
            groupId = $group.groupId
            confidenceTier = $group.confidenceTier
            labels = @($group.labels)
            explanation = $group.explanation
            recommendationReason = $group.recommendationReason
            suggestedKeepPath = $group.suggestedKeepPath
            searchText = (@($group.groupId, $group.confidenceTier, ($group.labels -join ' '), $group.suggestedKeepPath, $group.recommendationReason) -join ' ')
            items = @($group.items | ForEach-Object {
                $date = Get-DateProposal -Item $_
                $proposedDate = if ($null -ne $date) { $date.proposedCaptureTimeUtc } else { $null }
                $modifiedTime = Get-ReviewValue -Object $_ -Name 'modifiedTime'
                $accessState = Get-ReviewValue -Object $_ -Name 'accessState'
                $error = Get-ReviewValue -Object $_ -Name 'error'
                $warning = Get-ReviewValue -Object $_ -Name 'warning'
                $evidence = @(Get-ReviewValue -Object $_ -Name 'evidence')
                [ordered]@{
                    path = $_.path
                    filename = [IO.Path]::GetFileName($_.path)
                    dimensions = if ($null -ne $_.width -and $null -ne $_.height) { "$($_.width)x$($_.height)" } else { $null }
                    width = $_.width
                    height = $_.height
                    size = $_.size
                    modifiedTime = $modifiedTime
                    proposedDate = $proposedDate
                    suggestedKeep = ($_.path -eq $group.suggestedKeepPath)
                    accessState = $accessState
                    error = $error
                    warning = $warning
                    evidence = $evidence
                    searchText = (@($_.path, [IO.Path]::GetFileName($_.path), $_.width, $_.height, $_.size, $modifiedTime, $accessState, $error, $warning, $proposedDate, ($evidence | ConvertTo-Json -Depth 12 -Compress)) -join ' ')
                }
            })
        }
    }
    [ordered]@{
        schemaVersion = 1
        source = 'review-archive'
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        search = [ordered]@{ supported = $true; fields = @('groupId', 'confidenceTier', 'labels', 'path', 'filename', 'dimensions', 'size', 'modifiedTime', 'proposedDate', 'accessState', 'evidence'); query = 'Case-insensitive substring search over each group and item searchText.' }
        groupCount = $groups.Count
        groups = @($archiveGroups)
    } | ConvertTo-Json -Depth 30 | Set-Content -Path $JsonReportPath -Encoding UTF8
}

function Test-ItemProtected {
    param([object]$Item)
    if ($script:protectedOverrides.ContainsKey([string]$Item.path)) {
        return [bool]$script:protectedOverrides[[string]$Item.path]
    }
    return [bool]$Item.protected
}

Write-HtmlReport
Write-JsonReport
if ($ExportOnly) {
    [pscustomobject]@{ htmlReportPath = (Resolve-Path -LiteralPath $HtmlReportPath).Path; jsonReportPath = (Resolve-Path -LiteralPath $JsonReportPath).Path; groupCount = $groups.Count; exportOnly = $true }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'Photo Review'
$form.Width = 1120
$form.Height = 860
$form.MinimumSize = New-Object Drawing.Size(900, 650)
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

$selectedPreview = New-Object Windows.Forms.PictureBox
$selectedPreview.Dock = 'Fill'
$selectedPreview.SizeMode = 'Zoom'
$selectedPreview.BackColor = [Drawing.Color]::Black
$selectedPreview.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle

$selectedPreviewCaption = New-Object Windows.Forms.Label
$selectedPreviewCaption.Dock = 'Bottom'
$selectedPreviewCaption.Height = 28
$selectedPreviewCaption.Padding = New-Object Windows.Forms.Padding(8, 5, 8, 5)
$selectedPreviewCaption.BackColor = [Drawing.Color]::WhiteSmoke

$previewHost = New-Object Windows.Forms.Panel
$previewHost.Dock = 'Fill'
$previewHost.Controls.Add($selectedPreview)
$previewHost.Controls.Add($selectedPreviewCaption)

$right = New-Object Windows.Forms.TableLayoutPanel
$right.Dock = 'Fill'
$right.RowCount = 3
$right.ColumnCount = 1
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 58)))
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 20)))
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 22)))
$right.Controls.Add($previewHost, 0, 0)
$right.Controls.Add($images, 0, 1)
$right.Controls.Add($details, 0, 2)

$content = New-Object Windows.Forms.TableLayoutPanel
$content.Dock = 'Fill'
$content.ColumnCount = 2
$content.RowCount = 1
$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 420)))
$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
$content.Controls.Add($list, 0, 0)
$content.Controls.Add($right, 1, 0)
$form.Controls.Add($content)

$buttons = New-Object Windows.Forms.TableLayoutPanel
$buttons.Dock = 'Bottom'
$buttons.Height = 132
$buttons.Padding = New-Object Windows.Forms.Padding(8)
$buttons.ColumnCount = 1
$buttons.RowCount = 3
$buttons.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 33)))
$buttons.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 34)))
$buttons.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 33)))
$form.Controls.Add($buttons)

function New-ReviewButtonArea {
    param([string]$Label, [int]$Row)
    $area = New-Object Windows.Forms.FlowLayoutPanel
    $area.Dock = 'Fill'
    $area.WrapContents = $false
    $area.AutoScroll = $true
    $area.FlowDirection = 'LeftToRight'
    $heading = New-Object Windows.Forms.Label
    $heading.Text = $Label
    $heading.AutoSize = $true
    $heading.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
    $heading.Padding = New-Object Windows.Forms.Padding(0, 7, 10, 0)
    $area.Controls.Add($heading)
    [void]$buttons.Controls.Add($area, 0, $Row)
    return $area
}

$navigationButtons = New-ReviewButtonArea -Label 'Navigate:' -Row 0
$decisionButtons = New-ReviewButtonArea -Label 'Decide:' -Row 1
$utilityButtons = New-ReviewButtonArea -Label 'Utilities:' -Row 2

function Add-ReviewButton {
    param([string]$Text, [scriptblock]$Action, [Windows.Forms.FlowLayoutPanel]$ButtonArea = $decisionButtons)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.Add_Click($Action)
    [void]$ButtonArea.Controls.Add($button)
    return $button
}

$script:currentIndex = 0
$script:currentItemIndex = 0
$script:isRefreshing = $false
$script:decisionNotice = 'No decision recorded for this group.'
$script:allGroups = @($groups)
$script:showReviewed = $false
$script:remainingGroupCount = $groups.Count
Update-ReviewQueue
function Get-CurrentGroup { if ($script:groups.Count -gt 0) { return $script:groups[$script:currentIndex] }; return $null }
function Get-CurrentItem { $group = Get-CurrentGroup; if ($null -eq $group) { return $null }; $items = @($group.items); if ($items.Count -eq 0) { return $null }; return $items[[math]::Min($script:currentItemIndex, $items.Count - 1)] }
function Set-SelectedItem {
    param([int]$Index)
    $script:currentItemIndex = $Index
    Refresh-Review
}

function Get-DetachedPreviewImage {
    param([string]$Path)

    $source = [Drawing.Image]::FromFile($Path)
    try {
        return [Drawing.Bitmap]::new($source)
    }
    finally {
        $source.Dispose()
    }
}

function Clear-PreviewImage {
    param([Windows.Forms.PictureBox]$PictureBox)

    if ($null -ne $PictureBox.Image) {
        $PictureBox.Image.Dispose()
        $PictureBox.Image = $null
    }
}

function Refresh-Review {
    $script:isRefreshing = $true
    try {
    $group = Get-CurrentGroup
    $list.Items.Clear()
    foreach ($control in @($images.Controls)) {
        foreach ($child in @($control.Controls)) {
            if ($child -is [Windows.Forms.PictureBox]) { Clear-PreviewImage -PictureBox $child }
            $child.Dispose()
        }
        $control.Dispose()
    }
    $images.Controls.Clear()
    Clear-PreviewImage -PictureBox $selectedPreview
    if ($null -eq $group) {
        $header.Text = 'Review complete — close this window to continue'
        $selectedPreviewCaption.Text = ''
        $details.Text = 'All available groups have decisions. Click "Finish review" below to return to Photo Manager, then run the dry-run.'
        return
    }
    $groupDecisionKey = "group:$($group.groupId)"
    if ($decisionMap.ContainsKey($groupDecisionKey)) {
        $savedGroupDecision = $decisionMap[$groupDecisionKey]
        $script:decisionNotice = switch ([string]$savedGroupDecision.action) {
            'defer' { "Deferred: $($group.groupId)"; break }
            'keep' { "Keep recorded: $($savedGroupDecision.keepPath). $([math]::Max(0, @($group.items).Count - 1)) non-keeper(s) are queued for the remediation dry run."; break }
            'quarantine-requested' { "Quarantine requested: $($group.groupId)"; break }
            default { "Decision recorded: $($savedGroupDecision.action)"; break }
        }
    }
    else {
        $itemDecisionCount = [int](($decisionMap.Values | Where-Object { [string](Get-ReviewValue -Object $_ -Name 'groupId') -eq [string]$group.groupId } | Measure-Object).Count)
        $script:decisionNotice = if ($itemDecisionCount -gt 0) { "$itemDecisionCount item-level decision(s) recorded for this group." } else { 'No decision recorded for this group.' }
    }
    $previousButton.Enabled = ($script:currentIndex -gt 0)
    $nextButton.Enabled = ($script:currentIndex -lt $script:groups.Count - 1)
    $reviewStatus = if ($script:showReviewed) { "showing all; $script:remainingGroupCount unreviewed" } else { "$script:remainingGroupCount unreviewed" }
    $header.Text = "Group $($script:currentIndex + 1) of $($script:groups.Count) | $reviewStatus | $($group.confidenceTier) | $($group.labels -join ', ')"
    foreach ($item in @($group.items)) { [void]$list.Items.Add([string]$item.path) }
    $list.SelectedIndex = [math]::Min($currentItemIndex, [math]::Max(0, $list.Items.Count - 1))
    $selectedItem = Get-CurrentItem
    $selectedPreviewCaption.Text = if ($null -ne $selectedItem) { "Selected item $($script:currentItemIndex + 1) of $(@($group.items).Count): $([IO.Path]::GetFileName($selectedItem.path))" } else { '' }
    if ($null -ne $selectedItem) {
        try {
            if (Test-Path -LiteralPath $selectedItem.path) {
                $selectedPreview.Image = Get-DetachedPreviewImage -Path $selectedItem.path
            }
        }
        catch {
            $selectedPreviewCaption.Text = "Preview unavailable: $($selectedItem.path)"
        }
    }
    $details.Text = "Decision: $script:decisionNotice`r`nSelected item: $($selectedItem.path)`r`nConfidence: $($group.confidenceTier)`r`nLabels: $($group.labels -join ', ')`r`nSuggested keep: $($group.suggestedKeepPath)`r`nReason: $($group.recommendationReason)`r`n`r`nExplanation/evidence:`r`n$(($group.explanation | ConvertTo-Json -Depth 20))`r`n`r`n" + (($group.items | ForEach-Object { $date = Get-DateProposal -Item $_; $proposed = if ($null -ne $date) { $date.proposedCaptureTimeUtc } else { 'n/a' }; $modified = if ($null -ne $_.modifiedTime) { $_.modifiedTime } else { 'n/a' }; $access = if ($_.accessState) { $_.accessState } else { 'available/unreported' }; $evidence = @(Get-ReviewValue -Object $_ -Name 'evidence'); "$($_.path)`r`n  Filename: $([IO.Path]::GetFileName($_.path))`r`n  Size: $($_.size)  Dimensions: $($_.width)x$($_.height)  Modified: $modified  Difference: $($_.perceptualDifference)`r`n  Proposed date: $proposed  Suggested keep: $($_.path -eq $group.suggestedKeepPath)  Protected: $(Test-ItemProtected $_)  Access: $access  Warning: $($_.warning)  Error: $($_.error)`r`n  Complete evidence: $($evidence | ConvertTo-Json -Depth 20 -Compress)" }) -join "`r`n`r`n")
    $itemIndex = 0
    foreach ($item in @($group.items)) {
        $capturedIndex = $itemIndex
        $panel = New-Object Windows.Forms.Panel
        $panel.Width = 210
        $panel.Height = 150
        $panel.BorderStyle = if ($capturedIndex -eq $script:currentItemIndex) { [Windows.Forms.BorderStyle]::Fixed3D } else { [Windows.Forms.BorderStyle]::None }
        $panel.BackColor = if ($capturedIndex -eq $script:currentItemIndex) { [Drawing.Color]::LightSteelBlue } else { [Drawing.Color]::White }
        $picture = New-Object Windows.Forms.PictureBox
        $picture.Width = 200
        $picture.Height = 105
        $picture.SizeMode = 'Zoom'
        $picture.Top = 0
        $picture.Left = 0
        $selectAction = { Set-SelectedItem -Index $capturedIndex }.GetNewClosure()
        try {
            if (Test-Path -LiteralPath $item.path) { $picture.Image = Get-DetachedPreviewImage -Path $item.path }
            else { throw 'File is unavailable.' }
        }
        catch {
            $fallback = New-Object Windows.Forms.Label
            $fallback.Text = "Preview unavailable`r`n$($item.path)"
            $fallback.AutoSize = $false
            $fallback.Width = 200
            $fallback.Height = 105
            $fallback.TextAlign = 'MiddleCenter'
            $fallback.Add_Click($selectAction)
            $panel.Controls.Add($fallback)
        }
        if ($null -ne $picture.Image) { $panel.Controls.Add($picture) }
        $caption = New-Object Windows.Forms.Label
        $caption.Text = [IO.Path]::GetFileName($item.path)
        $caption.Top = 108
        $caption.Width = 200
        $caption.Height = 38
        $caption.BackColor = $panel.BackColor
        $caption.Font = if ($capturedIndex -eq $script:currentItemIndex) { New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold) } else { New-Object Drawing.Font('Segoe UI', 9) }
        $panel.Controls.Add($caption)
        $panel.Add_Click($selectAction)
        $picture.Add_Click($selectAction)
        $caption.Add_Click($selectAction)
        $images.Controls.Add($panel)
        $itemIndex++
    }
    }
    finally {
        $script:isRefreshing = $false
    }
}

$list.Add_SelectedIndexChanged({ if (-not $script:isRefreshing) { $script:currentItemIndex = [math]::Max(0, $list.SelectedIndex); Refresh-Review } })

$previousButton = Add-ReviewButton -Text 'Previous' -ButtonArea $navigationButtons -Action { if ($script:currentIndex -gt 0) { $script:currentIndex--; $script:currentItemIndex = 0; Refresh-Review } }
$nextButton = Add-ReviewButton -Text 'Next' -ButtonArea $navigationButtons -Action { if ($script:currentIndex -lt $script:groups.Count - 1) { $script:currentIndex++; $script:currentItemIndex = 0; Refresh-Review } }
Add-ReviewButton -Text 'Keep suggestion' -Action {
    $group = Get-CurrentGroup
    if ($null -ne $group) {
        $suggestedIndex = 0
        foreach ($item in @($group.items)) {
            if ($item.path -eq $group.suggestedKeepPath) { break }
            $suggestedIndex++
        }
        $script:currentItemIndex = [math]::Min($suggestedIndex, @($group.items).Count - 1)
        $decision = [pscustomobject]@{ groupId = $group.groupId; action = 'keep'; keepPath = $group.suggestedKeepPath; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $decisionMap[(Get-ReviewDecisionKey -Decision $decision)] = $decision
        Save-Decisions $decisionMap
        $script:decisionNotice = "Keep suggestion recorded: $($group.suggestedKeepPath)"
        Refresh-Review
    }
} | Out-Null
Add-ReviewButton -Text 'Choose selected keep' -Action {
    $group = Get-CurrentGroup
    $item = Get-CurrentItem
    if ($null -ne $group -and $null -ne $item) { $decision = [pscustomobject]@{ groupId = $group.groupId; action = 'keep'; keepPath = $item.path; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; $decisionMap[(Get-ReviewDecisionKey -Decision $decision)] = $decision; Save-Decisions $decisionMap; $script:decisionNotice = "Selected keep recorded: $($item.path)"; Refresh-Review }
} | Out-Null
Add-ReviewButton -Text 'Queue quarantine' -Action {
    $group = Get-CurrentGroup
    if ($null -ne $group -and [Windows.Forms.MessageBox]::Show('Record a quarantine request for this group? No files will be moved in Phase 5.', 'Confirm request', 'YesNo', 'Warning') -eq 'Yes') {
        foreach ($item in @($group.items | Where-Object { $_.path -ne $group.suggestedKeepPath })) {
            $decision = [pscustomobject]@{ groupId = $group.groupId; path = $item.path; action = 'quarantine-requested'; sha256 = (Get-DecisionSha256 -Path $item.path); decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            $decisionMap[(Get-ReviewDecisionKey -Decision $decision)] = $decision
        }
        Save-Decisions $decisionMap
        Refresh-Review
    }
} | Out-Null
Add-ReviewButton -Text 'Queue selected quarantine' -Action {
    $group = Get-CurrentGroup
    $item = Get-CurrentItem
    if ($null -ne $group -and $null -ne $item -and [Windows.Forms.MessageBox]::Show('Record a quarantine request for the selected item? No files will be moved in Phase 5.', 'Confirm request', 'YesNo', 'Warning') -eq 'Yes') {
        $decision = [pscustomobject]@{ groupId = $group.groupId; path = $item.path; action = 'quarantine-requested'; sha256 = (Get-DecisionSha256 -Path $item.path); decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; $decisionMap[(Get-ReviewDecisionKey -Decision $decision)] = $decision; Save-Decisions $decisionMap; Refresh-Review
    }
} | Out-Null
Add-ReviewButton -Text 'Skip / defer' -Action {
    $group = Get-CurrentGroup
    if ($null -ne $group) { $decision = [pscustomobject]@{ groupId = $group.groupId; action = 'defer'; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }; $decisionMap[(Get-ReviewDecisionKey -Decision $decision)] = $decision; Save-Decisions $decisionMap; $script:decisionNotice = "Deferred: $($group.groupId)"; Refresh-Review }
} | Out-Null
Add-ReviewButton -Text 'Protect selected' -Action {
    $group = Get-CurrentGroup
    $item = Get-CurrentItem
    if ($null -ne $group -and $null -ne $item) {
        $newProtected = -not (Test-ItemProtected $item)
        $script:protectedOverrides[[string]$item.path] = $newProtected
        $action = if ($newProtected) { 'protect' } else { 'unprotect' }
        $decision = [pscustomobject]@{ groupId = $group.groupId; path = $item.path; action = $action; protected = $newProtected; decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $decisionMap[(Get-ReviewDecisionKey -Decision $decision)] = $decision
        Save-Decisions $decisionMap
        $script:decisionNotice = "Protected: $newProtected for $($item.path)"
        Refresh-Review
    }
} | Out-Null
Add-ReviewButton -Text 'Open file' -ButtonArea $utilityButtons -Action { $item = Get-CurrentItem; if ($null -ne $item) { Start-Process -FilePath $item.path } } | Out-Null
Add-ReviewButton -Text 'Open folder' -ButtonArea $utilityButtons -Action { $item = Get-CurrentItem; if ($null -ne $item) { Start-Process explorer.exe -ArgumentList "/select,`"$($item.path)`"" } } | Out-Null
Add-ReviewButton -Text 'Finish review' -ButtonArea $utilityButtons -Action { $form.Close() } | Out-Null
$showReviewedButton = Add-ReviewButton -Text 'Show reviewed groups' -ButtonArea $utilityButtons -Action {
    $script:showReviewed = -not $script:showReviewed
    $showReviewedButton.Text = if ($script:showReviewed) { 'Hide reviewed groups' } else { 'Show reviewed groups' }
    Update-ReviewQueue
    Refresh-Review
}

Refresh-Review
[void]$form.ShowDialog()
