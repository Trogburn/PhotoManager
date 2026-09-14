[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'PhotoManager'),
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$payloadRoot = $PSScriptRoot
$exeSource = Join-Path $payloadRoot 'PhotoManager.exe'
if (-not (Test-Path -LiteralPath $exeSource)) {
    throw "PhotoManager.exe was not found next to this installer. Extract the zip first, then run Install.bat."
}
if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot 'tools\czkawka\scan.ps1'))) {
    throw "Workflow tools are missing from this package (tools\\czkawka\\scan.ps1)."
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Write-Host "Installing Photo Manager to $InstallRoot"
Get-ChildItem -LiteralPath $payloadRoot -Force |
    Where-Object { $_.Name -notin @('Install.bat', 'Install-PhotoManager.ps1') } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $InstallRoot $_.Name) -Recurse -Force
    }

$installedExe = Join-Path $InstallRoot 'PhotoManager.exe'
if (-not (Test-Path -LiteralPath $installedExe)) {
    throw "Install failed; $installedExe is missing."
}

$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-Item -ItemType Directory -Path $programs -Force | Out-Null
$shortcutPath = Join-Path $programs 'Photo Manager.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $installedExe
$shortcut.WorkingDirectory = $InstallRoot
$shortcut.Description = 'Review-first photo duplicate and date workflow'
$shortcut.Save()

Write-Host "Installed. Start Menu shortcut: $shortcutPath"
Write-Host "Set a UNC scan root and a separate quarantine folder before the first scan."
if ($Launch) {
    Start-Process -FilePath $installedExe -WorkingDirectory $InstallRoot
}
