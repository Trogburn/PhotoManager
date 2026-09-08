[CmdletBinding()]
param(
    [string]$Version = '12.0.1',
    [string]$InstallDirectory = 'C:\Tools\czkawka',
    [string]$Checksum = '',
    [switch]$SkipChecksum,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ExpectedArchiveName {
    param([string]$RequestedVersion)

    $knownNames = @(
        'windows_czkawka_cli_x86_64.zip',
        'windows_czkawka_cli_x86_64.exe',
        'windows_czkawka_cli.zip'
    )

    foreach ($name in $knownNames) {
        if ($name) {
            return $name
        }
    }

    throw "No known Windows CLI asset name is configured for version $RequestedVersion. Update the script with the pinned release asset name."
}

$archiveName = Get-ExpectedArchiveName -RequestedVersion $Version
$downloadUrl = "https://github.com/qarmin/czkawka/releases/download/$Version/$archiveName"
$archivePath = Join-Path ([System.IO.Path]::GetTempPath()) "czkawka-$Version.zip"
$installDir = [System.IO.Path]::GetFullPath($InstallDirectory)
$exePath = Join-Path $installDir 'czkawka_cli.exe'

if ((Test-Path $exePath) -and -not $Force) {
    Write-Host "Czkawka CLI already installed at $exePath. Use -Force to re-download and replace the binary."
    [pscustomobject]@{
        Version = $Version
        DownloadUrl = $downloadUrl
        InstallDirectory = $installDir
        ExePath = $exePath
        Result = 'AlreadyInstalled'
    }
    return
}

New-Item -Path $installDir -ItemType Directory -Force | Out-Null

if (-not $SkipChecksum) {
    if ([string]::IsNullOrWhiteSpace($Checksum)) {
        throw "A pinned SHA256 checksum is required for version $Version. Re-run with -Checksum <hash> or -SkipChecksum to bypass verification only for testing."
    }

    $normalizedChecksum = ($Checksum.Trim()).ToLowerInvariant()
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing | Out-Null
    $actualChecksum = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actualChecksum -ne $normalizedChecksum) {
        throw "Checksum mismatch for $downloadUrl. Expected $normalizedChecksum but found $actualChecksum."
    }
}
else {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing | Out-Null
}

if (Test-Path $archivePath) {
    if (Test-Path $exePath) {
        Remove-Item -Path $exePath -Force
    }

    try {
        Expand-Archive -Path $archivePath -DestinationPath $installDir -Force
    }
    catch {
        throw "Failed to extract $archivePath. The archive may not match the pinned Windows CLI package name for version $Version."
    }
}

if (-not (Test-Path $exePath)) {
    $nestedExe = Get-ChildItem -Path $installDir -Filter 'czkawka_cli.exe' -Recurse -File | Select-Object -First 1
    if ($nestedExe) {
        $exePath = $nestedExe.FullName
    }
    else {
        throw "Expected czkawka_cli.exe in $installDir after extraction, but it was not found."
    }
}

& $exePath --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "The installed CLI was not runnable: $exePath returned exit code $LASTEXITCODE."
}

Write-Host "Installed Czkawka CLI version $Version to $exePath"
[pscustomobject]@{
    Version = $Version
    DownloadUrl = $downloadUrl
    InstallDirectory = $installDir
    ExePath = $exePath
    Result = 'Installed'
}
