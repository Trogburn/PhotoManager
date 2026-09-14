[CmdletBinding()]
param(
    [ValidateSet('Local', 'Network', 'GoldenCorpus')]
    [string]$Mode = 'Local',

    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Real lab UNC paths belong in qnap-lab.local.json or QNAP_LAB_ALLOWED_ROOT,
# never in committed source. Network mode still requires an exact match.
$HarnessVersion = 2

function Assert-SafeLabUnc {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        throw 'Lab root must be a UNC path of the form \\SERVER\Share[\optional-child].'
    }
    if ($Path -match '^[A-Za-z]:\\?$') {
        throw 'Drive roots are never valid lab roots.'
    }
    if ($Path -match '(?i)\\(production|prod|photos|media|home|public)(\\|$)') {
        throw 'Production-like paths are not valid lab roots.'
    }
}

function Get-AllowedLabRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:QNAP_LAB_ALLOWED_ROOT)) {
        return $env:QNAP_LAB_ALLOWED_ROOT
    }

    $localPath = Join-Path $PSScriptRoot 'qnap-lab.local.json'
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
        $fromFile = [string]$local.allowedLabRoot
        if (-not [string]::IsNullOrWhiteSpace($fromFile)) {
            return $fromFile
        }
    }

    return $null
}

function Get-RequiredLabRoot {
    if ($env:QNAP_LAB_TESTS -cne '1') {
        throw 'Lab tests are disabled. Set QNAP_LAB_TESTS=1 explicitly.'
    }
    if ([string]::IsNullOrEmpty($env:QNAP_LAB_ROOT)) {
        throw 'QNAP_LAB_ROOT is required. Set it to your disposable lab UNC, or copy qnap-lab.local.json.example to qnap-lab.local.json.'
    }

    $allowed = Get-AllowedLabRoot
    if ($allowed -and $env:QNAP_LAB_ROOT -cne $allowed) {
        throw 'QNAP_LAB_ROOT must exactly equal the allowlisted lab UNC from qnap-lab.local.json or QNAP_LAB_ALLOWED_ROOT.'
    }

    Assert-SafeLabUnc -Path $env:QNAP_LAB_ROOT
    return $env:QNAP_LAB_ROOT
}

function Assert-LabChild {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)

    $rootWithSlash = "$Root\"
    if (-not $Path.StartsWith($rootWithSlash, [StringComparison]::Ordinal)) {
        throw "Refusing path outside the exact lab root: $Path"
    }
    $relative = $Path.Substring($rootWithSlash.Length)
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^|\\)\.\.?($|\\)') {
        throw "Refusing lab-root parent or root path: $Path"
    }
    if ($Path -match '^[A-Za-z]:\\' -or $Path -match '(?i)(^|\\)(production|prod|photos|media|home|public)(\\|$)') {
        throw "Refusing drive-root or production-like lab path: $Path"
    }
}

function New-UniqueChild {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$Prefix = 'run')

    do {
        $child = Join-Path $Root "$Prefix-$([guid]::NewGuid().ToString('N'))"
    } while (Test-Path -LiteralPath $child)
    Assert-LabChild -Path $child -Root $Root
    return $child
}

function Assert-PathUnder {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside the lab run child: $Path"
    }
}

function New-ImageFixture {
    param([Parameter(Mandatory = $true)][string]$InputRoot)

    # A deterministic, valid 1x1 JPEG. Two identical files guarantee a safe
    # duplicate candidate without depending on production data.
    $jpeg = [Convert]::FromBase64String('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/AP/EABQQAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8Af//Z')
    $keep = Join-Path $InputRoot '2026-01-01_keep.jpg'
    $candidate = Join-Path $InputRoot '2026-01-01_candidate.jpg'
    [IO.File]::WriteAllBytes($keep, $jpeg)
    [IO.File]::WriteAllBytes($candidate, $jpeg)
    return @($keep, $candidate)
}

function Get-Snapshot {
    param([Parameter(Mandatory = $true)][string]$InputRoot)

    return @(Get-ChildItem -LiteralPath $InputRoot -File -Recurse | ForEach-Object {
        [ordered]@{
            path = $_.FullName
            size = [long]$_.Length
            lastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}

function Assert-SnapshotGate {
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][string]$InputRoot,
        [Parameter(Mandatory = $true)][object[]]$Decisions,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$Classified
    )

    foreach ($decision in $Decisions) {
        if ([string]$decision.action -ne 'keep') {
            throw "Harness only permits deterministic keep decisions; found '$($decision.action)'."
        }
        Assert-PathUnder -Path ([string]$decision.keepPath) -Root $RunRoot
    }
    $snapshotByPath = @{}
    foreach ($entry in $Snapshot) { $snapshotByPath[[string]$entry.path] = $entry }
    foreach ($group in @($Classified.groups)) {
        foreach ($item in @($group.items)) {
            $itemPath = [string]$item.path
            Assert-PathUnder -Path $itemPath -Root $RunRoot
            if (-not $snapshotByPath.ContainsKey($itemPath)) {
                throw "Snapshot gate found an un-snapshotted remediation candidate: $itemPath"
            }
        }
    }
    foreach ($entry in $snapshotByPath.Values) {
        Assert-PathUnder -Path ([string]$entry.path) -Root $InputRoot
        $current = Get-Item -LiteralPath ([string]$entry.path) -Force
        $hash = (Get-FileHash -LiteralPath $current.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($current.Length -ne [long]$entry.size -or $hash -ne [string]$entry.sha256) {
            throw "Snapshot gate failed; fixture changed before remediation: $($entry.path)"
        }
    }
}

function Write-Result {
    param([string]$ModeName, [string]$Status, [string]$Detail, [string]$ArtifactRoot)

    [pscustomobject]@{
        harnessVersion = $HarnessVersion
        mode = $ModeName
        status = $Status
        detail = $Detail
        artifactRoot = $ArtifactRoot
        networkAttempted = ($ModeName -eq 'Network')
        goldenCorpusAttempted = ($ModeName -eq 'GoldenCorpus')
        credentialsUsed = $false
        timestampUtc = [datetime]::UtcNow.ToString('o')
    }
}

$labRoot = if ($Mode -eq 'Local') { $null } else { Get-RequiredLabRoot }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$workflowTests = Join-Path $PSScriptRoot 'phase7-tests.ps1'
$artifactRoot = $null
$cleanup = $false

try {
    if ($Mode -eq 'Local') {
        # Local mode never contacts the lab UNC and does not require lab
        # credentials or an allowlist setting.
        $artifactRoot = Join-Path ([IO.Path]::GetTempPath()) "qnap-lab-local-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path $artifactRoot -ItemType Directory -Force | Out-Null
        $cleanup = $true
        & $workflowTests
        if ($LASTEXITCODE -ne 0) {
            throw "Safe local validation failed with exit code $LASTEXITCODE."
        }
        Write-Result -ModeName $Mode -Status 'passed' -Detail 'Local validation completed; no network test was run.' -ArtifactRoot $artifactRoot
        return
    }

    if ($Mode -eq 'Network') {
        $artifactRoot = New-UniqueChild -Root $labRoot -Prefix 'harness'
        $inputRoot = Join-Path $artifactRoot 'Input'
        $quarantineRoot = Join-Path $artifactRoot 'Quarantine'
        New-Item -Path $inputRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $quarantineRoot -ItemType Directory -Force | Out-Null
        Assert-LabChild -Path $inputRoot -Root $labRoot
        Assert-LabChild -Path $quarantineRoot -Root $labRoot
        $cleanup = $true
        $config = Join-Path $repoRoot 'tools\czkawka\config.json'
        $configObject = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        $configObject.scan.localReportRoot = Join-Path $artifactRoot 'Reports'
        $configObject.scan.protectedPaths = @()
        $configObject.scan.excludedPaths = @()
        $configPath = Join-Path $artifactRoot 'network-test-config.json'
        $configObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $fixturePaths = New-ImageFixture -InputRoot $inputRoot
        $snapshot = Get-Snapshot -InputRoot $inputRoot
        $workflow = & (Join-Path $repoRoot 'tools\czkawka\run-workflow.ps1') `
            -ConfigPath $configPath -ScanRoot $inputRoot -Fresh -ExportOnly
        $workflow = @($workflow | Where-Object { $null -ne $_.PSObject.Properties['classifiedPath'] }) | Select-Object -Last 1
        if ($null -eq $workflow) { throw 'Network workflow did not return a result object.' }
        $classifiedPath = [string]$workflow.classifiedPath
        $decisionPath = Join-Path $artifactRoot 'decisions.json'
        $classified = Get-Content -LiteralPath $classifiedPath -Raw | ConvertFrom-Json
        $groups = @($classified.groups)
        if ($groups.Count -eq 0) { throw 'Network fixture produced no duplicate/image group.' }
        $decisions = @($groups | Sort-Object groupId | ForEach-Object {
            [ordered]@{ groupId = [string]$_.groupId; action = 'keep'; keepPath = [string]$_.suggestedKeepPath }
        })
        $decisions | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $decisionPath -Encoding UTF8
        # This is the harness equivalent of the remediation safety gate:
        # decisions and every source file must still be confined and unchanged.
        Assert-SnapshotGate -Snapshot $snapshot -InputRoot $inputRoot -Decisions $decisions `
            -RunRoot $artifactRoot -Classified $classified

        $manifestPath = Join-Path $artifactRoot 'transactions.jsonl'
        $remediate = Join-Path $repoRoot 'tools\czkawka\remediate.ps1'
        $dryRun = & $remediate -InputPath $classifiedPath -DecisionPath $decisionPath `
            -ConfigPath $configPath -ScanRoot $inputRoot -QuarantineRoot $quarantineRoot `
            -TransactionManifestPath $manifestPath
        if ($dryRun.dryRun -ne $true -or $dryRun.failed -ne 0 -or $dryRun.refused -ne 0 -or $dryRun.dryRunCount -lt 1) {
            throw "Network remediation dry-run failed: $($dryRun | ConvertTo-Json -Depth 10)"
        }
        $apply = & $remediate -InputPath $classifiedPath -DecisionPath $decisionPath `
            -ConfigPath $configPath -ScanRoot $inputRoot -QuarantineRoot $quarantineRoot `
            -TransactionManifestPath $manifestPath -Apply
        if ($apply.moved -lt 1 -or $apply.failed -ne 0) {
            throw "Network quarantine apply failed: $($apply | ConvertTo-Json -Depth 10)"
        }
        foreach ($path in $fixturePaths) { Assert-PathUnder -Path $path -Root $artifactRoot }
        $verifyOutput = Join-Path $artifactRoot 'Verification'
        $verify = & (Join-Path $repoRoot 'tools\czkawka\verify-remediation.ps1') `
            -InputPath $classifiedPath -DecisionPath $decisionPath `
            -TransactionManifestPath $manifestPath -ScanRoot $inputRoot `
            -QuarantineRoot $quarantineRoot -ConfigPath $configPath `
            -OutputDirectory $verifyOutput
        if ($verify.passed -ne $true) { throw 'Network remediation verification failed.' }
        & $remediate -DecisionPath $decisionPath -ConfigPath $configPath `
            -ScanRoot $inputRoot -QuarantineRoot $quarantineRoot `
            -TransactionManifestPath $manifestPath -Undo
        foreach ($entry in $snapshot) {
            if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) { throw "Undo did not restore $($entry.path)" }
            $restoredHash = (Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($restoredHash -ne [string]$entry.sha256) { throw "Restored file integrity mismatch: $($entry.path)" }
        }
        Write-Result -ModeName $Mode -Status 'passed' -Detail 'Network fixture lifecycle completed: scan, classify, dry-run, gated quarantine, verify, undo, and integrity restoration.' -ArtifactRoot $artifactRoot
        return
    }

    if ($env:QNAP_LAB_GOLDEN -cne '1') {
        throw 'Golden corpus mode requires QNAP_LAB_GOLDEN=1 explicitly.'
    }
    if ([string]::IsNullOrEmpty($env:QNAP_LAB_GOLDEN_PATH)) {
        throw 'Golden corpus mode requires QNAP_LAB_GOLDEN_PATH explicitly.'
    }
    Assert-LabChild -Path $env:QNAP_LAB_GOLDEN_PATH -Root $labRoot
    if (-not (Test-Path -LiteralPath $env:QNAP_LAB_GOLDEN_PATH -PathType Container)) {
        throw "Golden corpus path does not exist: $($env:QNAP_LAB_GOLDEN_PATH)"
    }
    if ($env:QNAP_LAB_GOLDEN_MANIFEST -and $env:QNAP_LAB_GOLDEN_CLASSIFIED -and $env:QNAP_LAB_GOLDEN_DATES) {
        & (Join-Path $PSScriptRoot 'validate-golden-corpus.ps1') `
            -ManifestPath $env:QNAP_LAB_GOLDEN_MANIFEST `
            -ClassifiedPath $env:QNAP_LAB_GOLDEN_CLASSIFIED `
            -DateReviewPath $env:QNAP_LAB_GOLDEN_DATES
        if ($LASTEXITCODE -ne 0) {
            throw "Golden corpus validation failed with exit code $LASTEXITCODE."
        }
    }
    else {
        throw 'Golden corpus mode requires QNAP_LAB_GOLDEN_MANIFEST, QNAP_LAB_GOLDEN_CLASSIFIED, and QNAP_LAB_GOLDEN_DATES.'
    }
    Write-Result -ModeName $Mode -Status 'passed' -Detail 'Explicitly enabled golden corpus validation completed.' -ArtifactRoot $env:QNAP_LAB_GOLDEN_PATH
}
finally {
    if ($cleanup -and -not $KeepArtifacts -and $artifactRoot -and (Test-Path -LiteralPath $artifactRoot)) {
        Remove-Item -LiteralPath $artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
