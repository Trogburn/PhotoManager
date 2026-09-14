# Persist opt-in lab environment variables from gitignored qnap-lab.local.json.
# Does not print the UNC path.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localPath = Join-Path $PSScriptRoot 'qnap-lab.local.json'
if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    throw "Missing $localPath. Copy qnap-lab.local.json.example and set allowedLabRoot."
}

$local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
$labRoot = [string]$local.allowedLabRoot
if ([string]::IsNullOrWhiteSpace($labRoot)) {
    throw 'qnap-lab.local.json must set allowedLabRoot.'
}

[Environment]::SetEnvironmentVariable('QNAP_LAB_TESTS', '1', 'User')
[Environment]::SetEnvironmentVariable('QNAP_LAB_ROOT', $labRoot, 'User')
[Environment]::SetEnvironmentVariable('QNAP_LAB_ALLOWED_ROOT', $labRoot, 'User')
$env:QNAP_LAB_TESTS = '1'
$env:QNAP_LAB_ROOT = $labRoot
$env:QNAP_LAB_ALLOWED_ROOT = $labRoot

Write-Host 'User environment now has QNAP_LAB_TESTS, QNAP_LAB_ROOT, and QNAP_LAB_ALLOWED_ROOT from qnap-lab.local.json.'
Write-Host 'New terminals pick those up automatically. This session is already updated.'
