[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [string]$ScanRoot,

    [Parameter()]
    [switch]$Fresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$effectiveScanRoot = if ($ScanRoot) { $ScanRoot } else { $config.scan.uncRoot }
$executablePath = $config.czkawka.exePath
$baseReportRoot = $config.scan.localReportRoot

if (-not (Test-Path -Path $executablePath)) {
    throw "Czkawka executable not found at $executablePath. Run tools/czkawka/install.ps1 first."
}

if ([string]::IsNullOrWhiteSpace($effectiveScanRoot)) {
    throw 'A scan root is required. Provide -ScanRoot or set scan.uncRoot in the config file.'
}

if (-not $effectiveScanRoot.StartsWith('\\')) {
    throw "The scan root must be a UNC path such as \\server\share\Photos. Received: $effectiveScanRoot"
}

if (-not (Test-Path -Path $effectiveScanRoot)) {
    throw "The UNC scan root does not exist or is not accessible: $effectiveScanRoot"
}

$timeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $baseReportRoot "scan-$timeStamp"
$rawDir = Join-Path $reportDir 'raw'
$metadataDir = Join-Path $reportDir 'metadata'

New-Item -Path $rawDir -ItemType Directory -Force | Out-Null
New-Item -Path $metadataDir -ItemType Directory -Force | Out-Null

function Invoke-CzkawkaScan {
    param(
        [string]$Mode,
        [string]$Root,
        [string]$RawOutputPath,
        [string]$MetadataPath,
        [switch]$DisableCache
    )

    $args = @(
        $Mode,
        '-d', $Root,
        '-C',
        '-W',
        '-N'
    )

    if ($DisableCache) {
        $args += '-H'
    }

    switch ($Mode) {
        'dup' {
            $args += @('-s', 'hash')
        }
        'image' {
            $args += @('--threshold', '8', '--algorithm', 'gradient', '--hash-size', '16')
            if ($config.scan.image.geometricInvariance) {
                $args += '--geometric-invariance'
            }
        }
    }

    $start = Get-Date
    $output = & $executablePath @args 2>&1
    $exitCode = $LASTEXITCODE
    $end = Get-Date

    $outputText = if ($null -ne $output) { ($output | Out-String).TrimEnd() } else { '' }
    $outputText | Set-Content -Path $RawOutputPath -Encoding UTF8

    $metadata = [ordered]@{
        schemaVersion = 1
        mode = $Mode
        scanRoot = $Root
        executable = $executablePath
        startUtc = $start.ToUniversalTime().ToString('o')
        endUtc = $end.ToUniversalTime().ToString('o')
        durationSeconds = [math]::Round(($end - $start).TotalSeconds, 3)
        exitCode = $exitCode
        rawOutput = $RawOutputPath
        fresh = $DisableCache
        arguments = $args
        requestedExitCodes = @($config.scan.allowedExitCodes)
    }

    $metadata | ConvertTo-Json -Depth 6 | Set-Content -Path $MetadataPath -Encoding UTF8

    if ($exitCode -notin @($config.scan.allowedExitCodes)) {
        throw "Czkawka $Mode scan failed with exit code $exitCode. Raw artifacts were preserved in $reportDir."
    }

    return [pscustomobject]@{
        Mode = $Mode
        ExitCode = $exitCode
        RawOutputPath = $RawOutputPath
        MetadataPath = $MetadataPath
        Output = $outputText
    }
}

$results = @()
$results += Invoke-CzkawkaScan -Mode 'dup' -Root $effectiveScanRoot -RawOutputPath (Join-Path $rawDir 'dup.json') -MetadataPath (Join-Path $metadataDir 'dup.metadata.json') -DisableCache:$Fresh
$results += Invoke-CzkawkaScan -Mode 'image' -Root $effectiveScanRoot -RawOutputPath (Join-Path $rawDir 'image.json') -MetadataPath (Join-Path $metadataDir 'image.metadata.json') -DisableCache:$Fresh

$summary = [ordered]@{
    schemaVersion = 1
    scanRoot = $effectiveScanRoot
    reportDir = $reportDir
    scanCompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
    results = @(
        $results | ForEach-Object {
            [ordered]@{
                mode = $_.Mode
                exitCode = $_.ExitCode
                rawOutputPath = $_.RawOutputPath
                metadataPath = $_.MetadataPath
            }
        }
    )
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $reportDir 'summary.json') -Encoding UTF8

Write-Host "Scan completed. Report root: $reportDir"
$results | Format-Table -AutoSize Mode, ExitCode, RawOutputPath
