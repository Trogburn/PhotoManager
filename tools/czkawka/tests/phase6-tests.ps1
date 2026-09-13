[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "qnap-phase6-$([guid]::NewGuid().ToString('N'))"
$source = Join-Path $root 'source'
$quarantine = Join-Path $root 'quarantine'
New-Item -Path $source -ItemType Directory -Force | Out-Null
try {
    $keep = Join-Path $source 'keep.jpg'
    $move = Join-Path $source 'move.jpg'
    $protected = Join-Path $source 'protected.jpg'
    $stale = Join-Path $source 'stale.jpg'
    $excluded = Join-Path $source 'excluded.jpg'
    $sameShare = Join-Path $source 'same-share.jpg'
    $permissionSource = Join-Path $source 'permission.jpg'
    'keep' | Set-Content $keep -Encoding UTF8
    'move' | Set-Content $move -Encoding UTF8
    'protected' | Set-Content $protected -Encoding UTF8
    'stale' | Set-Content $stale -Encoding UTF8
    'excluded' | Set-Content $excluded -Encoding UTF8
    'same share' | Set-Content $sameShare -Encoding UTF8
    'permission' | Set-Content $permissionSource -Encoding UTF8

    . (Join-Path $PSScriptRoot '..\common-hash.ps1')
    $hashProbe = Join-Path $root 'hash-probe.txt'
    'sha-probe' | Set-Content $hashProbe -Encoding UTF8
    $dotnetHash = Get-Sha256Hex -LiteralPath $hashProbe
    if ($dotnetHash -notmatch '^[0-9a-f]{64}$') {
        throw 'Get-Sha256Hex did not return a SHA-256 hex digest.'
    }
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        $cmdletHash = (Get-FileHash -LiteralPath $hashProbe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($dotnetHash -ne $cmdletHash) {
            throw 'Get-Sha256Hex did not match Get-FileHash.'
        }
    }

    $entries = foreach ($path in @($keep, $move, $protected, $stale, $excluded, $sameShare, $permissionSource)) {
        $file = Get-Item $path
        $hash = if ($path -eq $move) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        [ordered]@{ path = $file.FullName; size = $file.Length; modifiedTime = $file.LastWriteTimeUtc.ToString('o'); hash = $hash; width = $null; height = $null; perceptualDifference = $null; isReference = ($path -eq $protected); referenceState = if ($path -eq $protected) { 'reference' } else { 'not-set' } }
    }
    $classified = [ordered]@{
        schemaVersion = 1
        source = 'classifier'
        scanRoot = $source
        groups = @([ordered]@{ groupId = 'phase6-group'; suggestedKeepPath = $keep; items = $entries })
    }
    $classifiedPath = Join-Path $root 'classified.json'
    $classified | ConvertTo-Json -Depth 10 | Set-Content $classifiedPath -Encoding UTF8
    $configPath = Join-Path $root 'config.json'
    @{ scan = @{ protectedPaths = @(); excludedPaths = @($excluded); preferredDirectories = @() } } | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
    $decisionsPath = Join-Path $root 'decisions.json'
    @([ordered]@{ groupId = 'phase6-group'; action = 'keep'; keepPath = $keep }) | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $manifest = Join-Path $root 'transactions.jsonl'

    $dry = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $classifiedPath -DecisionPath $decisionsPath -ConfigPath $configPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest
    if (-not $dry.dryRun -or $dry.dryRunCount -ne 4 -or @($dry.results | Where-Object reason -eq 'excluded').Count -ne 1 -or -not (Test-Path $move) -or -not (Test-Path $protected)) {
        throw 'Keep decision did not preserve its keeper or identify non-keeper quarantine candidates.'
    }
    if ((Test-Path $manifest) -or (Test-Path $quarantine)) { throw 'Dry-run unexpectedly created a quarantine artifact.' }

    $protectedDecision = @([ordered]@{ path = $protected; action = 'quarantine-requested' })
    $protectedDecision += [ordered]@{ path = $move; action = 'quarantine-requested' }
    $protectedDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $apply = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $classifiedPath -DecisionPath $decisionsPath -ConfigPath $configPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest -Apply
    if ($apply.moved -ne 1 -or (Test-Path $move) -or -not (Test-Path $manifest)) {
        throw "Approved quarantine did not move exactly one requested file and log it. Summary: $($apply | ConvertTo-Json -Depth 8)"
    }
    $movedDestination = @($apply.results | Where-Object status -eq 'moved')[0].destination
    if (-not (Test-Path $movedDestination)) { throw 'Moved file was not found at its quarantine destination.' }
    $loggedMove = @(Get-Content $manifest | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object source -eq $move)[0]
    if ($null -eq $loggedMove.preMove -or $loggedMove.preMove.sha256 -ne (Get-FileHash $movedDestination -Algorithm SHA256).Hash.ToLowerInvariant() -or
        $null -eq $loggedMove.postMove -or $loggedMove.postMove.sha256 -ne $loggedMove.preMove.sha256) {
        throw 'Transaction evidence did not contain matching pre-move and post-move file evidence.'
    }

    $collisionSource = Join-Path $source 'collision.jpg'
    'collision' | Set-Content $collisionSource -Encoding UTF8
    New-Item -Path $quarantine -ItemType Directory -Force | Out-Null
    'existing destination' | Set-Content (Join-Path $quarantine 'collision.jpg') -Encoding UTF8
    $collisionDecision = @([ordered]@{ path = $collisionSource; action = 'quarantine-requested' })
    $collisionDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $collisionInput = [ordered]@{ schemaVersion = 1; source = 'classifier'; scanRoot = $source; groups = @([ordered]@{ groupId = 'collision'; suggestedKeepPath = ''; items = @([ordered]@{ path = $collisionSource; size = (Get-Item $collisionSource).Length; modifiedTime = (Get-Item $collisionSource).LastWriteTimeUtc.ToString('o'); protected = $false }) }) }
    $collisionPath = Join-Path $root 'collision.json'
    $collisionInput | ConvertTo-Json -Depth 10 | Set-Content $collisionPath -Encoding UTF8
    $collision = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $collisionPath -DecisionPath $decisionsPath -ConfigPath $configPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest -Apply
    if ($collision.moved -ne 1 -or $collision.results[0].destination -eq $movedDestination) { throw 'Collision-safe destination was not generated.' }

    $collisionDestination = [string]$collision.results[0].destination
    $undoList = Join-Path $root 'undo-one.txt'
    $move | Set-Content -LiteralPath $undoList -Encoding UTF8
    $fileUndoOut = Join-Path $root 'file-undo.out.txt'
    $fileUndoErr = Join-Path $root 'file-undo.err.txt'
    $fileUndo = Start-Process -FilePath powershell.exe -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot '..\remediate.ps1'),
        '-DecisionPath', $decisionsPath,
        '-ConfigPath', $configPath,
        '-QuarantineRoot', $quarantine,
        '-ScanRoot', $source,
        '-TransactionManifestPath', $manifest,
        '-Undo',
        '-UndoSourcePathFile', $undoList
    ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $fileUndoOut -RedirectStandardError $fileUndoErr
    if ($fileUndo.ExitCode -ne 0) {
        throw "powershell.exe -File selective undo failed: $((Get-Content -LiteralPath $fileUndoErr -Raw))"
    }
    if (-not (Test-Path -LiteralPath $move) -or (Test-Path -LiteralPath $movedDestination)) {
        throw 'powershell.exe -File selective undo did not restore the requested file.'
    }
    if (-not (Test-Path -LiteralPath $collisionDestination)) {
        throw 'powershell.exe -File selective undo restored an unrequested file.'
    }

    $staleFile = Get-Item $stale
    $staleExpectedSize = $staleFile.Length
    $staleExpectedModifiedTimeUtc = $staleFile.LastWriteTimeUtc.ToString('o')
    'changed' | Add-Content $stale
    $staleDecision = @([ordered]@{ path = $stale; action = 'quarantine-requested' })
    $staleDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $staleInput = [ordered]@{ schemaVersion = 1; source = 'classifier'; scanRoot = $source; groups = @([ordered]@{ groupId = 'stale'; suggestedKeepPath = ''; items = @([ordered]@{ path = $stale; size = $staleExpectedSize; modifiedTime = $staleExpectedModifiedTimeUtc; protected = $false }) }) }
    $stalePath = Join-Path $root 'stale.json'
    $staleInput | ConvertTo-Json -Depth 10 | Set-Content $stalePath -Encoding UTF8
    $staleResult = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $stalePath -DecisionPath $decisionsPath -ConfigPath $configPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest -Apply
    if ($staleResult.refused -ne 1 -or -not (Test-Path $stale)) { throw 'Stale file was not refused.' }

    $sameShareQuarantine = Join-Path $source 'same-share-quarantine'
    $sameShareDecision = @([ordered]@{ path = $sameShare; action = 'quarantine-requested' })
    $sameShareDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $sameShareInput = [ordered]@{ schemaVersion = 1; source = 'classifier'; scanRoot = $source; groups = @([ordered]@{ groupId = 'same-share'; suggestedKeepPath = ''; items = @($entries | Where-Object path -eq $sameShare) }) }
    $sameSharePath = Join-Path $root 'same-share.json'
    $sameShareInput | ConvertTo-Json -Depth 10 | Set-Content $sameSharePath -Encoding UTF8
    $sameShareResult = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $sameSharePath -DecisionPath $decisionsPath -ConfigPath $configPath -QuarantineRoot $sameShareQuarantine -TransactionManifestPath $manifest -Apply
    if ($sameShareResult.moved -ne 1 -or (Test-Path $sameShare) -or -not (Test-Path (Join-Path $sameShareQuarantine 'same-share.jpg'))) { throw 'Same-share quarantine verification failed.' }

    $permissionRoot = Join-Path $root 'permission-quarantine'
    New-Item -Path $permissionRoot -ItemType Directory -Force | Out-Null
    $permissionDecision = @([ordered]@{ path = $permissionSource; action = 'quarantine-requested' })
    $permissionDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $permissionInput = [ordered]@{ schemaVersion = 1; source = 'classifier'; scanRoot = $source; groups = @([ordered]@{ groupId = 'permission'; suggestedKeepPath = ''; items = @($entries | Where-Object path -eq $permissionSource) }) }
    $permissionPath = Join-Path $root 'permission.json'
    $permissionInput | ConvertTo-Json -Depth 10 | Set-Content $permissionPath -Encoding UTF8
    $icacls = Get-Command icacls.exe -ErrorAction SilentlyContinue
    if ($null -ne $icacls) {
        $identity = "$env:USERDOMAIN\$env:USERNAME"
        & $icacls.Source $permissionRoot /deny "${identity}:(OI)(CI)(W)" | Out-Null
        try {
            $permissionResult = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $permissionPath -DecisionPath $decisionsPath -ConfigPath $configPath -QuarantineRoot $permissionRoot -TransactionManifestPath $manifest -Apply
            if ($permissionResult.failed -ne 1 -or -not (Test-Path $permissionSource)) { throw 'Permission-denied move was not safely refused and logged.' }
        }
        finally {
            & $icacls.Source $permissionRoot /remove:d $identity | Out-Null
        }
    }
    else {
        Write-Warning 'Permission-denied move test skipped: icacls.exe is unavailable.'
    }

    $remainingUndo = Join-Path $root 'undo-remaining.txt'
    @($collisionSource, $sameShare) | Set-Content -LiteralPath $remainingUndo -Encoding UTF8
    $undo = & (Join-Path $PSScriptRoot '..\remediate.ps1') -DecisionPath $decisionsPath -TransactionManifestPath $manifest -Undo -UndoSourcePathFile $remainingUndo
    if (-not (Test-Path $move) -or -not (Test-Path $collisionSource)) { throw "Undo did not restore the quarantined files. move=$move exists=$(Test-Path $move); collision=$collisionSource exists=$(Test-Path $collisionSource)" }

    Write-Host 'Phase 6 remediation tests passed.'
}
finally {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
