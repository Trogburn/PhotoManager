[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$toolRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installScript = Join-Path $toolRoot 'install.ps1'
$scanScript = Join-Path $toolRoot 'scan.ps1'
$configPath = Join-Path $toolRoot 'config.json'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "photo-phase1-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

function Test-ScriptSyntax {
    param([string]$Path)

    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "PowerShell syntax check failed for $Path : $($parseErrors[0].ToString())"
    }
}

function Get-ExceptionMessage {
    param($ErrorRecord)

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.InnerException) {
        return $ErrorRecord.Exception.InnerException.Message
    }
    if ($ErrorRecord.Exception) {
        return $ErrorRecord.Exception.Message
    }
    return [string]$ErrorRecord
}

try {
    Test-ScriptSyntax -Path $installScript
    Test-ScriptSyntax -Path $scanScript

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.czkawka.checksum -match 'REPLACE_|placeholder') {
        throw 'Pinned Czkawka checksum is still a placeholder.'
    }
    if ([IO.Path]::GetFileName($config.czkawka.downloadUrl) -ne 'windows_czkawka_cli.exe') {
        throw "Pinned download URL does not point at windows_czkawka_cli.exe: $($config.czkawka.downloadUrl)"
    }

    $missingExeConfig = Join-Path $tempRoot 'missing-exe.json'
    $missingConfigObject = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $missingConfigObject.czkawka.exePath = Join-Path $tempRoot 'missing-czkawka_cli.exe'
    $missingConfigObject.scan.localReportRoot = Join-Path $tempRoot 'reports-missing-exe'
    $missingConfigObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingExeConfig -Encoding utf8
    try {
        & $scanScript -ConfigPath $missingExeConfig -ScanRoot '\\photo-phase1-missing\photos' | Out-Null
        throw 'Missing executable unexpectedly succeeded.'
    }
    catch {
        $message = Get-ExceptionMessage -ErrorRecord $_
        if ($message -notlike '*Czkawka executable not found*') {
            throw "Missing executable error was not actionable: $message"
        }
    }

    $missingShareConfig = Join-Path $tempRoot 'missing-share.json'
    $shareConfigObject = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $shareConfigObject.czkawka.exePath = Join-Path $tempRoot 'placeholder-czkawka_cli.exe'
    'placeholder' | Set-Content -LiteralPath $shareConfigObject.czkawka.exePath -Encoding utf8
    $shareConfigObject.scan.localReportRoot = Join-Path $tempRoot 'reports-missing-share'
    $shareConfigObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $missingShareConfig -Encoding utf8
    try {
        & $scanScript -ConfigPath $missingShareConfig -ScanRoot '\\localhost\photo-phase1-missing-share' | Out-Null
        throw 'Missing share unexpectedly succeeded.'
    }
    catch {
        $message = Get-ExceptionMessage -ErrorRecord $_
        if ($message -notlike '*UNC scan root does not exist*' -and $message -notlike '*not accessible*') {
            throw "Missing share error was not actionable: $message"
        }
    }

    $localRejectConfig = Join-Path $tempRoot 'local-reject.json'
    $localRejectObject = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $localRejectObject.czkawka.exePath = $shareConfigObject.czkawka.exePath
    $localRejectObject.scan.localReportRoot = Join-Path $tempRoot 'reports-local-reject'
    $localRejectObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $localRejectConfig -Encoding utf8
    try {
        & $scanScript -ConfigPath $localRejectConfig -ScanRoot $tempRoot | Out-Null
        throw 'Local scan root without -AllowLocalRoot unexpectedly succeeded.'
    }
    catch {
        $message = Get-ExceptionMessage -ErrorRecord $_
        if ($message -notlike '*must be a UNC path*' -and $message -notlike '*AllowLocalRoot*') {
            throw "Local-root rejection was not actionable: $message"
        }
    }

    $installResult = & $installScript -ConfigPath $configPath
    $exePath = Join-Path $toolRoot 'bin\czkawka_cli.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "CLI was not installed at $exePath"
    }
    $versionText = (& $exePath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '12\.0\.1|czkawka') {
        throw "czkawka_cli.exe --version did not succeed after installation. Output: $versionText"
    }

    $invalidConfig = Join-Path $tempRoot 'invalid-arg.json'
    $invalidObject = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $invalidObject.scan.localReportRoot = Join-Path $tempRoot 'reports-invalid'
    $invalidObject.scan.image.algorithm = 'not-a-real-hash-algorithm'
    $invalidObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $invalidConfig -Encoding utf8
    $invalidRoot = Join-Path $tempRoot 'invalid-scan-root'
    New-Item -Path $invalidRoot -ItemType Directory -Force | Out-Null
    try {
        & $scanScript -ConfigPath $invalidConfig -ScanRoot $invalidRoot -AllowLocalRoot | Out-Null
        throw 'Invalid Czkawka argument unexpectedly succeeded.'
    }
    catch {
        $message = Get-ExceptionMessage -ErrorRecord $_
        if ($message -notlike '*failed with exit code*' -and $message -notlike '*invalid*' -and $message -notlike '*hash-alg*') {
            throw "Invalid argument error was not actionable: $message"
        }
    }

    Add-Type -AssemblyName System.Drawing
    $fixtureRoot = Join-Path $tempRoot 'fixture'
    New-Item -Path $fixtureRoot -ItemType Directory -Force | Out-Null
    $jpegPath = Join-Path $fixtureRoot 'original.jpg'
    $bitmap = New-Object Drawing.Bitmap 96, 96
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::SteelBlue)
            $graphics.FillRectangle([Drawing.Brushes]::Orange, 8, 8, 40, 40)
        }
        finally {
            $graphics.Dispose()
        }
        $bitmap.Save($jpegPath, [Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally {
        $bitmap.Dispose()
    }
    Copy-Item -LiteralPath $jpegPath -Destination (Join-Path $fixtureRoot 'original-copy.jpg') -Force

    $beforeHashes = @{}
    Get-ChildItem -LiteralPath $fixtureRoot -File | ForEach-Object {
        $beforeHashes[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $_.Refresh()
        $beforeHashes["$($_.FullName)|write"] = $_.LastWriteTimeUtc.ToString('o')
    }

    $scanConfig = Join-Path $tempRoot 'scan-config.json'
    $scanObject = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $scanObject.scan.localReportRoot = Join-Path $tempRoot 'reports-scan'
    $scanObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scanConfig -Encoding utf8

    $scanResult = & $scanScript -ConfigPath $scanConfig -ScanRoot $fixtureRoot -AllowLocalRoot -Fresh
    $reportDir = [string]$scanResult.reportDir
    $dupRaw = Join-Path $reportDir 'raw\dup.json'
    $imageRaw = Join-Path $reportDir 'raw\image.json'
    $dupMeta = Join-Path $reportDir 'metadata\dup.metadata.json'
    $imageMeta = Join-Path $reportDir 'metadata\image.metadata.json'
    $dupErr = Join-Path $reportDir 'diagnostics\dup.stderr.log'
    $imageErr = Join-Path $reportDir 'diagnostics\image.stderr.log'
    $summaryPath = Join-Path $reportDir 'summary.json'
    foreach ($required in @($dupRaw, $imageRaw, $dupMeta, $imageMeta, $dupErr, $imageErr, $summaryPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Local fixture scan did not produce required artifact: $required"
        }
    }

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $dupMetadata = Get-Content -LiteralPath $dupMeta -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$summary.czkawkaVersion) -or [string]$summary.czkawkaVersion -ne [string]$dupMetadata.czkawkaVersion) {
        throw 'Scan summary did not preserve the actual Czkawka CLI version.'
    }
    if ([int]$dupMetadata.exitCode -notin @($config.scan.allowedExitCodes)) {
        throw "Finding/empty scan was treated as a process failure. Exit code $($dupMetadata.exitCode)"
    }
    $deletionFlags = @($dupMetadata.arguments | Where-Object { [string]::Equals($_, '-D', [StringComparison]::Ordinal) -or $_ -eq '--delete-method' -or $_ -eq '--delete-files' })
    if ($deletionFlags.Count -gt 0) {
        throw 'Scan arguments included a Czkawka deletion flag.'
    }
    if ($dupMetadata.rawOutput -ne $dupRaw -or $dupMetadata.standardError -ne $dupErr) {
        throw 'Scan metadata did not separate raw JSON from stderr diagnostics.'
    }

    $dupJson = Get-Content -LiteralPath $dupRaw -Raw
    $dupErrText = Get-Content -LiteralPath $dupErr -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($dupJson) -or $dupJson.Trim() -eq '{}' -or $dupJson.Trim() -eq '[]') {
        throw "Exact-duplicate fixture did not produce a finding in raw JSON. stderr: $dupErrText json: $dupJson"
    }
    if ($dupJson -notmatch '"hash"') {
        throw "Raw duplicate JSON did not contain hash evidence. stderr: $dupErrText json: $dupJson"
    }

    Get-ChildItem -LiteralPath $fixtureRoot -File | ForEach-Object {
        $currentHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        if ($currentHash -ne $beforeHashes[$_.FullName]) {
            throw "Scan changed fixture file content: $($_.FullName)"
        }
        $_.Refresh()
        if ($_.LastWriteTimeUtc.ToString('o') -ne $beforeHashes["$($_.FullName)|write"]) {
            throw "Scan changed fixture LastWriteTime: $($_.FullName)"
        }
    }

    function Test-PathTimed {
        param(
            [string]$PathValue,
            [int]$TimeoutSeconds = 5
        )

        $job = Start-Job -ScriptBlock { Test-Path -LiteralPath $using:PathValue }
        try {
            if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
                return [bool](Receive-Job -Job $job)
            }
            return $false
        }
        finally {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    $uncRoot = $null
    if ($fixtureRoot -match '^([A-Za-z]):\\(.*)$') {
        $uncCandidate = "\\localhost\$($Matches[1])`$\$($Matches[2])"
        if (Test-PathTimed -PathValue $uncCandidate) {
            $uncRoot = $uncCandidate
        }
    }
    if (-not $uncRoot -and -not [string]::IsNullOrWhiteSpace($env:PHOTO_SCAN_ROOT) -and $env:PHOTO_SCAN_ROOT.StartsWith('\\') -and (Test-PathTimed -PathValue $env:PHOTO_SCAN_ROOT)) {
        $uncRoot = $env:PHOTO_SCAN_ROOT
    }

    if ($uncRoot) {
        $uncConfig = Join-Path $tempRoot 'unc-config.json'
        $uncObject = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $uncObject.scan.localReportRoot = Join-Path $tempRoot 'reports-unc'
        $uncObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $uncConfig -Encoding utf8
        $uncResult = & $scanScript -ConfigPath $uncConfig -ScanRoot $uncRoot
        $uncSummary = Get-Content -LiteralPath $uncResult.summaryPath -Raw | ConvertFrom-Json
        if ($uncSummary.scanRoot -ne $uncRoot) {
            throw "UNC scan root did not round-trip. Expected $uncRoot, got $($uncSummary.scanRoot)"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $uncResult.reportDir 'raw\dup.json'))) {
            throw 'UNC scan did not write raw duplicate JSON locally.'
        }
        Write-Host "UNC scan succeeded against $uncRoot"
    }
    else {
        Write-Host 'UNC scan check skipped; no accessible UNC path was available for the local fixture.'
    }

    Write-Host 'Phase 1 Czkawka CLI foundation tests passed.'
    Write-Host "Installed CLI version: $versionText"
    if ($installResult) {
        Write-Host "Install result: $($installResult.Result)"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
