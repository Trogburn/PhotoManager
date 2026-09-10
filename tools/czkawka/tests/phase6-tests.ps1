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
    'keep' | Set-Content $keep -Encoding UTF8
    'move' | Set-Content $move -Encoding UTF8
    'protected' | Set-Content $protected -Encoding UTF8
    'stale' | Set-Content $stale -Encoding UTF8

    $entries = foreach ($path in @($keep, $move, $protected, $stale)) {
        $file = Get-Item $path
        [ordered]@{ path = $file.FullName; size = $file.Length; modifiedTime = $file.LastWriteTimeUtc.ToString('o'); hash = $null; width = $null; height = $null; perceptualDifference = $null; isReference = ($path -eq $protected); referenceState = if ($path -eq $protected) { 'reference' } else { 'not-set' } }
    }
    $classified = [ordered]@{
        schemaVersion = 1
        source = 'classifier'
        scanRoot = $source
        groups = @([ordered]@{ groupId = 'phase6-group'; suggestedKeepPath = $keep; items = $entries })
    }
    $classifiedPath = Join-Path $root 'classified.json'
    $classified | ConvertTo-Json -Depth 10 | Set-Content $classifiedPath -Encoding UTF8
    $decisionsPath = Join-Path $root 'decisions.json'
    @([ordered]@{ groupId = 'phase6-group'; action = 'quarantine-requested'; keepPath = $keep }) | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $manifest = Join-Path $root 'transactions.jsonl'

    $dry = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $classifiedPath -DecisionPath $decisionsPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest
    if (-not $dry.dryRun -or $dry.dryRunCount -ne 2 -or -not (Test-Path $move) -or -not (Test-Path $protected)) {
        throw 'Dry-run did not preserve source files or identify requested candidates.'
    }
    if (Test-Path $manifest) { throw 'Dry-run unexpectedly created a transaction manifest.' }

    $protectedDecision = @([ordered]@{ path = $protected; action = 'quarantine-requested' })
    $protectedDecision += [ordered]@{ path = $move; action = 'quarantine-requested' }
    $protectedDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $apply = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $classifiedPath -DecisionPath $decisionsPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest -Apply
    if ($apply.moved -ne 1 -or (Test-Path $move) -or -not (Test-Path $manifest)) {
        throw "Approved quarantine did not move exactly one requested file and log it. Summary: $($apply | ConvertTo-Json -Depth 8)"
    }
    $movedDestination = @($apply.results | Where-Object status -eq 'moved')[0].destination
    if (-not (Test-Path $movedDestination)) { throw 'Moved file was not found at its quarantine destination.' }

    $collisionSource = Join-Path $source 'collision.jpg'
    'collision' | Set-Content $collisionSource -Encoding UTF8
    New-Item -Path $quarantine -ItemType Directory -Force | Out-Null
    'existing destination' | Set-Content (Join-Path $quarantine 'collision.jpg') -Encoding UTF8
    $collisionDecision = @([ordered]@{ path = $collisionSource; action = 'quarantine-requested' })
    $collisionDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $collisionInput = [ordered]@{ schemaVersion = 1; source = 'classifier'; scanRoot = $source; groups = @([ordered]@{ groupId = 'collision'; suggestedKeepPath = ''; items = @([ordered]@{ path = $collisionSource; size = (Get-Item $collisionSource).Length; modifiedTime = (Get-Item $collisionSource).LastWriteTimeUtc.ToString('o'); protected = $false }) }) }
    $collisionPath = Join-Path $root 'collision.json'
    $collisionInput | ConvertTo-Json -Depth 10 | Set-Content $collisionPath -Encoding UTF8
    $collision = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $collisionPath -DecisionPath $decisionsPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest -Apply
    if ($collision.moved -ne 1 -or $collision.results[0].destination -eq $movedDestination) { throw 'Collision-safe destination was not generated.' }

    $staleFile = Get-Item $stale
    'changed' | Add-Content $stale
    $staleDecision = @([ordered]@{ path = $stale; action = 'quarantine-requested' })
    $staleDecision | ConvertTo-Json | Set-Content $decisionsPath -Encoding UTF8
    $staleInput = [ordered]@{ schemaVersion = 1; source = 'classifier'; scanRoot = $source; groups = @([ordered]@{ groupId = 'stale'; suggestedKeepPath = ''; items = @([ordered]@{ path = $stale; size = $staleFile.Length; modifiedTime = $staleFile.LastWriteTimeUtc.ToString('o'); protected = $false }) }) }
    $stalePath = Join-Path $root 'stale.json'
    $staleInput | ConvertTo-Json -Depth 10 | Set-Content $stalePath -Encoding UTF8
    $staleResult = & (Join-Path $PSScriptRoot '..\remediate.ps1') -InputPath $stalePath -DecisionPath $decisionsPath -QuarantineRoot $quarantine -TransactionManifestPath $manifest -Apply
    if ($staleResult.refused -ne 1 -or -not (Test-Path $stale)) { throw 'Stale file was not refused.' }

    $undo = & (Join-Path $PSScriptRoot '..\remediate.ps1') -DecisionPath $decisionsPath -TransactionManifestPath $manifest -Undo
    if (-not (Test-Path $move) -or -not (Test-Path $collisionSource)) { throw "Undo did not restore the quarantined files. move=$move exists=$(Test-Path $move); collision=$collisionSource exists=$(Test-Path $collisionSource)" }

    Write-Host 'Phase 6 remediation tests passed.'
}
finally {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
