# Shared scan identity for transaction manifests.
# A review only sees moves/undos stamped with its own scanId so leftover
# rows from an earlier apply cannot poison undo or verify.

function Get-PathFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )
    $full = [IO.Path]::GetFullPath($LiteralPath).ToLowerInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($full)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant().Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ScanFolderName {
    param([string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return $null }
    $full = [IO.Path]::GetFullPath($LiteralPath)
    $parent = Split-Path -Parent $full
    if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
    $name = Split-Path -Leaf $parent
    if ($name -match '^scan-') { return $name }
    $grandParent = Split-Path -Parent $parent
    if ([string]::IsNullOrWhiteSpace($grandParent)) { return $null }
    $grandName = Split-Path -Leaf $grandParent
    if ((Split-Path -Leaf $parent) -eq 'normalized' -and $grandName -match '^scan-') {
        return $grandName
    }
    return $null
}

function Get-ResolvedScanId {
    param(
        [object]$Classified,
        [string]$ClassifiedPath,
        [string]$InputPath
    )
    if ($null -ne $Classified -and $null -ne $Classified.PSObject.Properties['scanId']) {
        $stated = [string]$Classified.scanId
        if (-not [string]::IsNullOrWhiteSpace($stated)) {
            return $stated.Trim()
        }
    }
    foreach ($candidate in @($ClassifiedPath, $InputPath)) {
        $folder = Get-ScanFolderName -LiteralPath $candidate
        if (-not [string]::IsNullOrWhiteSpace($folder)) {
            return $folder
        }
    }
    $fingerprintPath = if (-not [string]::IsNullOrWhiteSpace($InputPath)) { $InputPath } else { $ClassifiedPath }
    if ([string]::IsNullOrWhiteSpace($fingerprintPath)) {
        throw 'A classified path is required to resolve scanId.'
    }
    return 'classified-' + (Get-PathFingerprint -LiteralPath $fingerprintPath)
}

function Select-TransactionHistoryForScan {
    param(
        [object[]]$History,
        [string]$ScanId,
        [switch]$RequireScanId
    )
    $normalized = if ([string]::IsNullOrWhiteSpace($ScanId)) { '' } else { $ScanId.Trim() }
    if ($RequireScanId.IsPresent -and [string]::IsNullOrWhiteSpace($normalized)) {
        $ids = @(
            $History | ForEach-Object {
                if ($null -ne $_.PSObject.Properties['scanId'] -and -not [string]::IsNullOrWhiteSpace([string]$_.scanId)) {
                    [string]$_.scanId
                }
            } | Sort-Object -Unique
        )
        if ($ids.Count -gt 1) {
            throw "Transaction manifest contains multiple scans ($($ids -join ', ')). Pass -InputPath or -ScanId to choose one."
        }
        if ($ids.Count -eq 1) {
            $normalized = $ids[0]
        }
    }
    @($History | Where-Object {
        $entryId = if ($null -ne $_.PSObject.Properties['scanId']) { [string]$_.scanId } else { '' }
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            [string]::IsNullOrWhiteSpace($entryId)
        }
        else {
            $entryId -eq $normalized
        }
    })
}
