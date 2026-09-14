[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [string]$ScanRoot,

    [Parameter()]
    [switch]$Fresh,

    [Parameter()]
    [switch]$AllowLocalRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param(
        [object]$Value,
        [string]$Name
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) {
        return $null
    }
    return $Value.PSObject.Properties[$Name].Value
}

function Resolve-ConfiguredPath {
    param(
        [string]$PathValue,
        [string]$RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }
    if ([IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }
    return [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $PathValue))
}

function Get-CliVersion {
    param([string]$ExecutablePath)

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $ExecutablePath --version 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    $text = if ($null -ne $output) { ($output | Out-String).Trim() } else { '' }
    if ($exitCode -ne 0) {
        throw "Unable to read Czkawka version from $ExecutablePath. Exit code $exitCode. Output: $text"
    }
    return $text
}

function Assert-ReadOnlyArguments {
    param([string[]]$Arguments)

    $forbidden = @('-D', '--delete-method', '--delete-files', '-y', '--move-to-trash')
    foreach ($argument in $Arguments) {
        foreach ($flag in $forbidden) {
            if ([string]::Equals($argument, $flag, [StringComparison]::Ordinal)) {
                throw "Refusing to launch Czkawka with deletion flag '$argument'."
            }
        }
    }
}

function Convert-ToWindowsCommandLineArgument {
    param([string]$Value)

    if ($Value.Length -eq 0) {
        return '""'
    }

    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-CzkawkaProcess {
    param(
        [string]$ExecutablePath,
        [string[]]$Arguments,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath
    )

    Assert-ReadOnlyArguments -Arguments $Arguments
    $process = $null
    $stdout = $null
    $stderr = $null
    try {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $ExecutablePath
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.CreateNoWindow = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [Text.Encoding]::UTF8
        if ($null -ne $info.PSObject.Properties['ArgumentList']) {
            foreach ($argument in $Arguments) {
                [void]$info.ArgumentList.Add($argument)
            }
        }
        else {
            $info.Arguments = (@($Arguments | ForEach-Object { Convert-ToWindowsCommandLineArgument -Value $_ }) -join ' ')
        }

        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    [IO.File]::WriteAllText($StandardOutputPath, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($StandardErrorPath, $stderr, [Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $stdout
        StandardError = $stderr
    }
}

. (Join-Path $PSScriptRoot 'common-config.ps1')
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-CzkawkaConfig -ConfigPath $ConfigPath
$effectiveScanRoot = if ($ScanRoot) { $ScanRoot } else { [string]$config.scan.uncRoot }
$executablePath = Resolve-ConfiguredPath -PathValue ([string]$config.czkawka.exePath) -RepositoryRoot $repositoryRoot
$baseReportRoot = Resolve-ConfiguredPath -PathValue ([string]$config.scan.localReportRoot) -RepositoryRoot $repositoryRoot
$allowedExitCodes = @($config.scan.allowedExitCodes | ForEach-Object { [int]$_ })
if ($allowedExitCodes.Count -eq 0) {
    $allowedExitCodes = @(0, 11)
}

if (-not (Test-Path -LiteralPath $executablePath)) {
    throw "Czkawka executable not found at $executablePath. Run tools/czkawka/install.ps1 first."
}

if ([string]::IsNullOrWhiteSpace($effectiveScanRoot)) {
    throw 'A scan root is required. Provide -ScanRoot or set scan.uncRoot in the config file.'
}
if ($effectiveScanRoot -match 'YOUR-SERVER|YOUR-SHARE') {
    throw "The scan root still contains a placeholder UNC value: $effectiveScanRoot"
}

$isUnc = $effectiveScanRoot.StartsWith('\\')
if (-not $isUnc -and -not $AllowLocalRoot) {
    throw "The scan root must be a UNC path such as \\server\share\Photos, or pass -AllowLocalRoot for a local fixture. Received: $effectiveScanRoot"
}
if ($isUnc -and $effectiveScanRoot -notmatch '^\\\\[^\\]+\\[^\\]+') {
    throw "The UNC scan root must be a share path such as \\server\share or \\server\share\Photos. Received: $effectiveScanRoot"
}
if (-not (Test-Path -LiteralPath $effectiveScanRoot)) {
    if ($isUnc) {
        throw "The UNC scan root does not exist or is not accessible: $effectiveScanRoot"
    }
    throw "The local scan root does not exist or is not accessible: $effectiveScanRoot"
}

$cliVersion = Get-CliVersion -ExecutablePath $executablePath
$timeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $baseReportRoot "scan-$timeStamp"
$rawDir = Join-Path $reportDir 'raw'
$metadataDir = Join-Path $reportDir 'metadata'
$diagnosticsDir = Join-Path $reportDir 'diagnostics'
New-Item -Path $rawDir -ItemType Directory -Force | Out-Null
New-Item -Path $metadataDir -ItemType Directory -Force | Out-Null
New-Item -Path $diagnosticsDir -ItemType Directory -Force | Out-Null

function Get-ScanArguments {
    param(
        [string]$Mode,
        [string]$Root,
        [string]$RawOutputPath,
        [switch]$DisableCache
    )

    $arguments = @(
        $Mode,
        '-d', $Root,
        '-C', $RawOutputPath,
        '-W',
        '-N'
    )

    if ($DisableCache) {
        $arguments += '-H'
    }

    $modeConfigName = if ($Mode -eq 'dup') { 'duplicate' } else { $Mode }
    $modeConfig = Get-PropertyValue -Value $config.scan -Name $modeConfigName
    $excluded = @()
    $excluded += @($(Get-PropertyValue -Value $config.scan -Name 'excludedPaths'))
    $excluded += @($(Get-PropertyValue -Value $modeConfig -Name 'excludePaths'))
    foreach ($excludedPath in @($excluded | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $arguments += @('-e', [string]$excludedPath)
    }

    switch ($Mode) {
        'dup' {
            $subMode = [string](Get-PropertyValue -Value $config.scan.duplicate -Name 'subMode')
            if ([string]::IsNullOrWhiteSpace($subMode)) { $subMode = 'hash' }
            $arguments += @('--search-method', $subMode.ToUpperInvariant())
            $minSize = Get-PropertyValue -Value $config.scan.duplicate -Name 'minimalFileSize'
            if ($null -ne $minSize) {
                $arguments += @('--minimal-file-size', [string][long]$minSize)
            }
        }
        'image' {
            $threshold = Get-PropertyValue -Value $config.scan.image -Name 'threshold'
            if ($null -eq $threshold) { $threshold = 8 }
            $algorithm = [string](Get-PropertyValue -Value $config.scan.image -Name 'algorithm')
            if ([string]::IsNullOrWhiteSpace($algorithm)) { $algorithm = 'Gradient' }
            $hashSize = Get-PropertyValue -Value $config.scan.image -Name 'hashSize'
            if ($null -eq $hashSize) { $hashSize = 16 }
            $arguments += @(
                '--max-difference', [string]$threshold,
                '--hash-alg', $algorithm,
                '--hash-size', [string]$hashSize
            )
            $minSize = Get-PropertyValue -Value $config.scan.image -Name 'minimalFileSize'
            if ($null -ne $minSize) {
                $arguments += @('--minimal-file-size', [string][long]$minSize)
            }
            $geometric = Get-PropertyValue -Value $config.scan.image -Name 'geometricInvariance'
            if ($geometric -is [string] -and -not [string]::IsNullOrWhiteSpace($geometric) -and $geometric -ne 'off') {
                $arguments += @('--geometric-invariance', [string]$geometric)
            }
            elseif ($geometric -eq $true) {
                $arguments += @('--geometric-invariance', 'mirror-flip')
            }
        }
        default {
            throw "Unsupported Czkawka scan mode '$Mode'. Use dup or image."
        }
    }

    return @($arguments)
}

function Invoke-CzkawkaScan {
    param(
        [string]$Mode,
        [string]$Root,
        [string]$RawOutputPath,
        [string]$MetadataPath,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath,
        [switch]$DisableCache
    )

    $arguments = Get-ScanArguments -Mode $Mode -Root $Root -RawOutputPath $RawOutputPath -DisableCache:$DisableCache
    $start = Get-Date
    $processResult = Invoke-CzkawkaProcess -ExecutablePath $executablePath -Arguments $arguments -StandardOutputPath $StandardOutputPath -StandardErrorPath $StandardErrorPath
    $end = Get-Date
    $exitCode = [int]$processResult.ExitCode

    if (-not (Test-Path -LiteralPath $RawOutputPath)) {
        [IO.File]::WriteAllText($RawOutputPath, '', [Text.UTF8Encoding]::new($false))
    }

    $metadata = [ordered]@{
        schemaVersion = 1
        mode = $Mode
        scanRoot = $Root
        executable = $executablePath
        czkawkaVersion = $cliVersion
        startUtc = $start.ToUniversalTime().ToString('o')
        endUtc = $end.ToUniversalTime().ToString('o')
        durationSeconds = [math]::Round(($end - $start).TotalSeconds, 3)
        exitCode = $exitCode
        rawOutput = $RawOutputPath
        standardOutput = $StandardOutputPath
        standardError = $StandardErrorPath
        fresh = [bool]$DisableCache
        arguments = @($arguments)
        requestedExitCodes = @($allowedExitCodes)
        readOnly = $true
    }
    $metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $MetadataPath -Encoding utf8

    if ($exitCode -notin $allowedExitCodes) {
        $errorTail = if ($processResult.StandardError) { $processResult.StandardError.Trim() } else { $processResult.StandardOutput.Trim() }
        throw "Czkawka $Mode scan failed with exit code $exitCode. $errorTail Raw artifacts were preserved in $reportDir."
    }

    return [pscustomobject]@{
        Mode = $Mode
        ExitCode = $exitCode
        RawOutputPath = $RawOutputPath
        MetadataPath = $MetadataPath
        StandardOutputPath = $StandardOutputPath
        StandardErrorPath = $StandardErrorPath
        CzkawkaVersion = $cliVersion
    }
}

$results = @()
$results += Invoke-CzkawkaScan -Mode 'dup' -Root $effectiveScanRoot -RawOutputPath (Join-Path $rawDir 'dup.json') -MetadataPath (Join-Path $metadataDir 'dup.metadata.json') -StandardOutputPath (Join-Path $diagnosticsDir 'dup.stdout.log') -StandardErrorPath (Join-Path $diagnosticsDir 'dup.stderr.log') -DisableCache:$Fresh
$results += Invoke-CzkawkaScan -Mode 'image' -Root $effectiveScanRoot -RawOutputPath (Join-Path $rawDir 'image.json') -MetadataPath (Join-Path $metadataDir 'image.metadata.json') -StandardOutputPath (Join-Path $diagnosticsDir 'image.stdout.log') -StandardErrorPath (Join-Path $diagnosticsDir 'image.stderr.log') -DisableCache:$Fresh

$summary = [ordered]@{
    schemaVersion = 1
    scanRoot = $effectiveScanRoot
    reportDir = $reportDir
    czkawkaVersion = $cliVersion
    executable = $executablePath
    scanCompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
    fresh = [bool]$Fresh
    results = @(
        $results | ForEach-Object {
            [ordered]@{
                mode = $_.Mode
                exitCode = $_.ExitCode
                rawOutputPath = $_.RawOutputPath
                metadataPath = $_.MetadataPath
                standardOutputPath = $_.StandardOutputPath
                standardErrorPath = $_.StandardErrorPath
                czkawkaVersion = $_.CzkawkaVersion
            }
        }
    )
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $reportDir 'summary.json') -Encoding utf8

Write-Host "Scan completed. Report root: $reportDir"
$results | Format-Table -AutoSize Mode, ExitCode, RawOutputPath | Out-Host
return [pscustomobject]@{
    reportDir = $reportDir
    summaryPath = Join-Path $reportDir 'summary.json'
    czkawkaVersion = $cliVersion
    scanRoot = $effectiveScanRoot
    results = $results
}
