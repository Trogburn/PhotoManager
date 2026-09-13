[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReviewPath,[Parameter(Mandatory)][string]$DecisionPath,[string]$HtmlReportPath,[string]$JsonReportPath,[int]$SamplesPerSource=25)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
$report=Get-Content $ReviewPath -Raw|ConvertFrom-Json
$all=@($report.items)
$audit=@{};if(Test-Path $DecisionPath){@((Get-Content $DecisionPath -Raw|ConvertFrom-Json)|Write-Output)|ForEach-Object{$audit[$_.path]=$_}}
function Sample($source,$confidence){$c=@($all|Where-Object{$_.status -eq 'Proposed' -and $_.source -eq $source -and $_.confidence -eq $confidence}|ForEach-Object{[pscustomobject]@{item=$_;year=([datetime]$_.proposedCaptureTimeUtc).Year;folder=Split-Path $_.path -Parent}}|Sort-Object year,folder,@{e={$_.item.path}});$b=@($c|Group-Object year,folder|ForEach-Object{$_.Group[0]});$r=@();for($i=0;$r.Count -lt $SamplesPerSource -and $i -lt $b.Count;$i++){$r+=$b[$i].item};$r}
$items=@((Sample 'exif-DateTimeOriginal' 'High')+(Sample 'filename' 'Medium'))
if($HtmlReportPath){$items|Select-Object path,currentCreationTimeUtc,proposedCaptureTimeUtc,source,confidence,timezoneOffset,reason|ConvertTo-Html|Set-Content $HtmlReportPath -Encoding UTF8}
if($JsonReportPath){[pscustomobject]@{summary=($all|Group-Object status,source,confidence|ForEach-Object{[pscustomobject]@{key=$_.Name;count=$_.Count}});samples=$items}|ConvertTo-Json -Depth 8|Set-Content $JsonReportPath -Encoding UTF8}
Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
$i=0;$f=New-Object Windows.Forms.Form -Property @{Text='Date Evidence Audit';Width=1200;Height=800};$pic=New-Object Windows.Forms.PictureBox -Property @{Dock='Fill';SizeMode='Zoom';BackColor='Black'};$info=New-Object Windows.Forms.TextBox -Property @{Dock='Bottom';Height=180;Multiline=$true;ReadOnly=$true};$bar=New-Object Windows.Forms.FlowLayoutPanel -Property @{Dock='Bottom';Height=45};$f.Controls.AddRange(@($pic,$info,$bar))
function Show{$x=$items[$script:i];if($pic.Image){$pic.Image.Dispose();$pic.Image=$null};try{$pic.Image=[Drawing.Image]::FromFile($x.path)}catch{};$info.Text="Sample $($script:i+1) of $($items.Count)`r`n$($x.path)`r`nCurrent CreationTime: $($x.currentCreationTimeUtc)`r`nProposed: $($x.proposedCaptureTimeUtc)`r`nSource: $($x.source) | Confidence: $($x.confidence)`r`nTimezone: $($x.timezoneOffset)`r`n$x.reason"}
function Decide($a){$x=$items[$script:i];$audit[$x.path]=[pscustomobject]@{path=$x.path;action=$a;decidedAtUtc=(Get-Date).ToUniversalTime().ToString('o')};@($audit.Values)|ConvertTo-Json|Set-Content $DecisionPath -Encoding UTF8;if($script:i -lt $items.Count-1){$script:i++};Show}
foreach($p in @(@('Previous',{if($script:i){$script:i--};Show}),@('Next',{if($script:i -lt $items.Count-1){$script:i++};Show}),@('Confirm sample',{Decide 'confirm-sample'}),@('Reject sample',{Decide 'reject-sample'}),@('Defer',{Decide 'defer'}))){$b=New-Object Windows.Forms.Button -Property @{Text=$p[0];AutoSize=$true};$b.Add_Click($p[1]);$bar.Controls.Add($b)}
Show;[void]$f.ShowDialog()
