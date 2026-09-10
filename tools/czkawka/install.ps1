[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDirectory,
    [string]$Checksum,
    [string]$DownloadUrl,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$SkipChecksum,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigObject {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-PlaceholderChecksum {
    param([string]$Value)

    return [string]::IsNullOrWhiteSpace($Value) -or $Value -match 'REPLACE_|YOUR-|placeholder'
}

$config = Get-ConfigObject -Path $ConfigPath
if (-not $Version) {
    $Version = if ($null -ne $config) { [string]$config.czkawka.version } else { '12.0.1' }
}
if (-not $InstallDirectory) {
    $InstallDirectory = if ($null -ne $config -and -not [string]::IsNullOrWhiteSpace([string]$config.czkawka.installDirectory) -and [IO.Path]::IsPathRooted([string]$config.czkawka.installDirectory)) {
        [string]$config.czkawka.installDirectory
    }
    else {
        Join-Path $PSScriptRoot 'bin'
    }
}
if (-not $DownloadUrl) {
    $DownloadUrl = if ($null -ne $config -and -not [string]::IsNullOrWhiteSpace([string]$config.czkawka.downloadUrl)) {
        [string]$config.czkawka.downloadUrl
    }
    else {
        "https://github.com/qarmin/czkawka/releases/download/$Version/windows_czkawka_cli.exe"
    }
}
if (-not $Checksum -and $null -ne $config) {
    $Checksum = [string]$config.czkawka.checksum
}

$installDir = [IO.Path]::GetFullPath($InstallDirectory)
$exePath = Join-Path $installDir 'czkawka_cli.exe'
$assetName = [IO.Path]::GetFileName(($DownloadUrl -split '\?')[0])
$downloadPath = Join-Path ([IO.Path]::GetTempPath()) "czkawka-$Version-$assetName"

if ((Test-Path -LiteralPath $exePath) -and -not $Force) {
    $existingVersion = (& $exePath --version 2>&1 | Out-String).Trim()
    Write-Host "Czkawka CLI already installed at $exePath. Use -Force to re-download and replace the binary."
    [pscustomobject]@{
        Version = $Version
        ActualVersion = $existingVersion
        DownloadUrl = $DownloadUrl
        InstallDirectory = $installDir
        ExePath = $exePath
        Checksum = $Checksum
        Result = 'AlreadyInstalled'
    }
    return
}

if (-not $SkipChecksum -and (Test-PlaceholderChecksum -Value $Checksum)) {
    throw "A pinned SHA256 checksum is required for version $Version. Set czkawka.checksum in $ConfigPath, or pass -Checksum <hash>. Use -SkipChecksum only for testing."
}

New-Item -Path $installDir -ItemType Directory -Force | Out-Null
Write-Host "Downloading $DownloadUrl"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloadPath -UseBasicParsing | Out-Null

if (-not $SkipChecksum) {
    $normalizedChecksum = ($Checksum.Trim()).ToLowerInvariant()
    if ($normalizedChecksum.StartsWith('sha256:')) {
        $normalizedChecksum = $normalizedChecksum.Substring(7)
    }
    $actualChecksum = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualChecksum -ne $normalizedChecksum) {
        throw "Checksum mismatch for $DownloadUrl. Expected $normalizedChecksum but found $actualChecksum."
    }
}

if (Test-Path -LiteralPath $exePath) {
    Remove-Item -LiteralPath $exePath -Force
}

$extension = [IO.Path]::GetExtension($downloadPath).ToLowerInvariant()
if ($extension -eq '.zip') {
    try {
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $installDir -Force
    }
    catch {
        throw "Failed to extract $downloadPath. The archive may not match the pinned Windows CLI package for version $Version."
    }
}
elseif ($extension -in @('.exe', '')) {
    Copy-Item -LiteralPath $downloadPath -Destination $exePath -Force
}
else {
    throw "Unsupported Czkawka asset type '$extension' from $DownloadUrl. Expected a .exe or .zip."
}

if (-not (Test-Path -LiteralPath $exePath)) {
    $nestedExe = Get-ChildItem -LiteralPath $installDir -Filter 'czkawka_cli.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nestedExe) {
        $nestedExe = Get-ChildItem -LiteralPath $installDir -Filter 'windows_czkawka_cli.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($nestedExe) {
        if ($nestedExe.FullName -ne $exePath) {
            Copy-Item -LiteralPath $nestedExe.FullName -Destination $exePath -Force
        }
    }
    else {
        throw "Expected czkawka_cli.exe in $installDir after installation, but it was not found."
    }
}

$actualVersion = (& $exePath --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "The installed CLI was not runnable: $exePath returned exit code $LASTEXITCODE. Output: $actualVersion"
}

Write-Host "Installed Czkawka CLI version $Version to $exePath"
[pscustomobject]@{
    Version = $Version
    ActualVersion = $actualVersion
    DownloadUrl = $DownloadUrl
    InstallDirectory = $installDir
    ExePath = $exePath
    Checksum = $Checksum
    Result = 'Installed'
}
