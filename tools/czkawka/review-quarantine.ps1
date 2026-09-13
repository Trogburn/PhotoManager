[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputPath,
    [Parameter(Mandatory)] [string]$DecisionPath,
    [Parameter(Mandatory)] [string]$TransactionManifestPath,
    [Parameter(Mandatory)] [string]$AuditDecisionPath,
    [string]$HtmlReportPath,
    [string]$JsonReportPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function JsonArray([string]$p) { @((Get-Content $p -Raw | ConvertFrom-Json) | Write-Output) }
function Save { @($audit.Values) | ConvertTo-Json | Set-Content $AuditDecisionPath -Encoding UTF8 }
$classified=Get-Content $InputPath -Raw|ConvertFrom-Json
$decisions=JsonArray $DecisionPath
$moved=@(Get-Content $TransactionManifestPath|ForEach-Object{$_|ConvertFrom-Json}|Where-Object status -eq moved)
$audit=@{}; if(Test-Path $AuditDecisionPath){foreach($d in JsonArray $AuditDecisionPath){$audit[$d.source]=$d}}
$items=@()
foreach($entry in $moved){
  $groups=@($classified.groups|Where-Object{@($_.items|Where-Object path -eq $entry.source).Count})
  $group=if($groups.Count){$groups[0]}else{$null}; $gd=if($group){@($decisions|Where-Object{$_.groupId -eq $group.groupId -and -not $_.PSObject.Properties['path']})|Select-Object -First 1}else{$null}
  $keeper=if($gd -and $gd.keepPath){$gd.keepPath}elseif($group){$group.suggestedKeepPath}else{$null}
  $items += [pscustomobject]@{source=$entry.source;quarantine=$entry.destination;keeper=$keeper;groupId=if($group){$group.groupId}else{'unmapped'};confidence=if($group){$group.confidenceTier}else{'unknown'};sha256=$entry.postMove.sha256;size=$entry.postMove.size;status=if($audit.ContainsKey($entry.source)){$audit[$entry.source].action}else{'pending'}}
}
if($HtmlReportPath){$items|ConvertTo-Html source,quarantine,keeper,groupId,confidence,status,sha256,size|Set-Content $HtmlReportPath -Encoding UTF8}
if($JsonReportPath){$items|ConvertTo-Json -Depth 5|Set-Content $JsonReportPath -Encoding UTF8}
Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
$pending=@($items|Where-Object status -eq pending); $all=$false; $index=0
$form=New-Object Windows.Forms.Form -Property @{Text='Quarantine Audit';Width=1400;Height=900}
$header=New-Object Windows.Forms.Label -Property @{Dock='Top';Height=35;Font=New-Object Drawing.Font('Segoe UI',12);Padding=New-Object Windows.Forms.Padding(8)}
$left=New-Object Windows.Forms.PictureBox -Property @{Dock='Left';Width=650;SizeMode='Zoom';BackColor='Black'}
$right=New-Object Windows.Forms.PictureBox -Property @{Dock='Fill';SizeMode='Zoom';BackColor='Black'}
$leftLabel=New-Object Windows.Forms.Label -Property @{Dock='Top';Height=24;Text='RETAINED KEEPER';TextAlign='MiddleCenter';Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)}
$rightLabel=New-Object Windows.Forms.Label -Property @{Dock='Top';Height=24;Text='QUARANTINED REMOVAL';TextAlign='MiddleCenter';Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)}
$leftHost=New-Object Windows.Forms.Panel -Property @{Dock='Fill'};$left.Dock='Fill';$leftHost.Controls.Add($left);$leftHost.Controls.Add($leftLabel)
$rightHost=New-Object Windows.Forms.Panel -Property @{Dock='Fill'};$rightHost.Controls.Add($right);$rightHost.Controls.Add($rightLabel)
$comparison=New-Object Windows.Forms.TableLayoutPanel -Property @{Dock='Fill';ColumnCount=2;RowCount=1}
$comparison.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)))
$comparison.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)))
$comparison.Controls.Add($leftHost,0,0);$comparison.Controls.Add($rightHost,1,0)
$detail=New-Object Windows.Forms.TextBox -Property @{Dock='Bottom';Height=130;Multiline=$true;ReadOnly=$true;ScrollBars='Vertical'}
$buttons=New-Object Windows.Forms.FlowLayoutPanel -Property @{Dock='Bottom';Height=45}
$form.Controls.AddRange(@($comparison,$detail,$buttons,$header))
function LoadImage($box,$path){if($box.Image){$box.Image.Dispose();$box.Image=$null};try{$box.Image=[Drawing.Image]::FromFile($path)}catch{}}
function Refresh{$list=@(if($all){$items}else{$pending});if($list.Count -eq 0){$header.Text='No pending audit items';return};$script:index=[math]::Max(0,[math]::Min($script:index,$list.Count-1));$x=$list[$script:index];$header.Text="Item $($script:index+1) of $($list.Count) | Keeper (left) vs quarantined removal (right)";LoadImage $left $x.keeper;LoadImage $right $x.quarantine;$detail.Text="Group: $($x.groupId)  Confidence: $($x.confidence)`r`nKeeper: $($x.keeper)`r`nQuarantine: $($x.quarantine)`r`nSHA-256: $($x.sha256)"}
function Act($action){$list=@(if($all){$items}else{$pending});if($list.Count){$x=$list[$script:index];$audit[$x.source]=[pscustomobject]@{source=$x.source;action=$action;decidedAtUtc=(Get-Date).ToUniversalTime().ToString('o')};Save;$script:pending=@($items|Where-Object{$audit.ContainsKey($_.source)-eq $false});Refresh}}
foreach($pair in @(@('Previous',{if($script:index -gt 0){$script:index--;Refresh}}),@('Next',{ $list=@(if($script:all){$items}else{$pending});if($script:index -lt $list.Count-1){$script:index++;Refresh}}),@('Confirm',{Act 'confirmed'}),@('Request restore',{Act 'restore-requested'}),@('Defer',{Act 'defer'}),@('Show audited',{ $script:all=-not $all;$this.Text=if($all){'Hide audited'}else{'Show audited'};$script:index=0;Refresh}))) {$b=New-Object Windows.Forms.Button -Property @{Text=$pair[0];AutoSize=$true};$b.Add_Click($pair[1]);$buttons.Controls.Add($b)}
Refresh;[void]$form.ShowDialog()
