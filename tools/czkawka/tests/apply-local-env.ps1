# Persist opt-in lab environment variables from gitignored photo-lab.local.json.
# Does not print the UNC path.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localPath = Join-Path $PSScriptRoot 'photo-lab.local.json'
if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    throw "Missing $localPath. Copy photo-lab.local.json.example and set allowedLabRoot."
}

$local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
$labRoot = [string]$local.allowedLabRoot
if ([string]::IsNullOrWhiteSpace($labRoot)) {
    throw 'photo-lab.local.json must set allowedLabRoot.'
}

[Environment]::SetEnvironmentVariable('PHOTO_LAB_TESTS', '1', 'User')
[Environment]::SetEnvironmentVariable('PHOTO_LAB_ROOT', $labRoot, 'User')
[Environment]::SetEnvironmentVariable('PHOTO_LAB_ALLOWED_ROOT', $labRoot, 'User')
$env:PHOTO_LAB_TESTS = '1'
$env:PHOTO_LAB_ROOT = $labRoot
$env:PHOTO_LAB_ALLOWED_ROOT = $labRoot

Write-Host 'User environment now has PHOTO_LAB_TESTS, PHOTO_LAB_ROOT, and PHOTO_LAB_ALLOWED_ROOT from photo-lab.local.json.'
Write-Host 'New terminals pick those up automatically. This session is already updated.'
