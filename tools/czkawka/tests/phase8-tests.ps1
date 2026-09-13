[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$toolRoot = Join-Path $repoRoot 'tools\czkawka'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "qnap-phase8-$([guid]::NewGuid().ToString('N'))"
$fixtureRoot = Join-Path $tempRoot 'fixture'
$reportRoot = Join-Path $tempRoot 'reports'
$quarantineRoot = Join-Path $tempRoot 'quarantine'
New-Item -Path $fixtureRoot -ItemType Directory -Force | Out-Null

function Get-ErrorText {
    param([object]$ErrorRecord)
    if ($ErrorRecord.Exception) {
        if ($ErrorRecord.Exception.InnerException) { return $ErrorRecord.Exception.InnerException.Message }
        return $ErrorRecord.Exception.Message
    }
    return [string]$ErrorRecord
}

function Assert-Path {
    param([string]$Path, [string]$Description)
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Description was not created: $Path" }
}

function Assert-Fails {
    param([scriptblock]$Action, [string]$ExpectedText)
    try {
        & $Action | Out-Null
        throw "Expected failure containing '$ExpectedText'."
    }
    catch {
        $message = Get-ErrorText $_
        if ($message -notlike "*$ExpectedText*") {
            throw "Unexpected failure. Expected '$ExpectedText', got '$message'."
        }
    }
}

try {
    # A checked-in malformed artifact makes parser error handling independent of hand-built test input.
    $parser = Join-Path $toolRoot 'parse-results.ps1'
    $corruptFixture = Join-Path $PSScriptRoot 'fixtures\corrupt-raw.json'
    Assert-Fails {
        & $parser -InputPath $corruptFixture -OutputPath (Join-Path $tempRoot 'corrupt.normalized.json')
    } 'Malformed JSON'

    $config = Get-Content -LiteralPath (Join-Path $toolRoot 'config.json') -Raw | ConvertFrom-Json
    $config.scan.localReportRoot = $reportRoot
    $config.scan.uncRoot = $fixtureRoot
    $config.scan.protectedPaths = @()
    $config.scan.excludedPaths = @()
    $configPath = Join-Path $tempRoot 'config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8

    # Use local, disposable files for both remediation verification and the workflow E2E.
    $keep = Join-Path $fixtureRoot '2024-01-02_keep.jpg'
    $candidate = Join-Path $fixtureRoot '2024-01-02_candidate.jpg'
    'same deterministic fixture bytes' | Set-Content -LiteralPath $keep -Encoding UTF8
    Copy-Item -LiteralPath $keep -Destination $candidate
    $keepInfo = Get-Item -LiteralPath $keep
    $candidateInfo = Get-Item -LiteralPath $candidate
    $classifiedPath = Join-Path $tempRoot 'classified.json'
    $classified = [ordered]@{
        schemaVersion = 1
        source = 'classifier'
        scanRoot = $fixtureRoot
        groups = @([ordered]@{
            groupId = 'phase8-exact'
            suggestedKeepPath = $keep
            items = @(
                [ordered]@{ path = $keep; size = $keepInfo.Length; modifiedTime = $keepInfo.LastWriteTimeUtc.ToString('o'); isReference = $false },
                [ordered]@{ path = $candidate; size = $candidateInfo.Length; modifiedTime = $candidateInfo.LastWriteTimeUtc.ToString('o'); isReference = $false }
            )
        })
    }
    $classified | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $classifiedPath -Encoding UTF8
    $decisionsPath = Join-Path $tempRoot 'decisions.json'
    @([ordered]@{ groupId = 'phase8-exact'; action = 'keep'; keepPath = $keep }) |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $decisionsPath -Encoding UTF8
    $manifestPath = Join-Path $tempRoot 'transactions.jsonl'

    $remediate = Join-Path $toolRoot 'remediate.ps1'
    $apply = & $remediate -InputPath $classifiedPath -DecisionPath $decisionsPath -ConfigPath $configPath `
        -ScanRoot $fixtureRoot -QuarantineRoot $quarantineRoot -TransactionManifestPath $manifestPath -Apply
    if ($apply.moved -ne 1 -or (Test-Path -LiteralPath $candidate) -or -not (Test-Path -LiteralPath $manifestPath)) {
        throw "Fixture quarantine did not move exactly one candidate: $($apply | ConvertTo-Json -Depth 10)"
    }

    $verify = Join-Path $toolRoot 'verify-remediation.ps1'
    $verifyOutput = Join-Path $tempRoot 'verification'
    $verified = & $verify -InputPath $classifiedPath -DecisionPath $decisionsPath `
        -TransactionManifestPath $manifestPath -ScanRoot $fixtureRoot -QuarantineRoot $quarantineRoot `
        -ConfigPath $configPath -OutputDirectory $verifyOutput -AllowLocalRoot
    Assert-Path (Join-Path $verifyOutput 'verification.json') 'Successful verification report'
    if (-not $verified.passed) { throw 'Successful remediation verification reported failure.' }

    # Tampering must invalidate the recorded post-move evidence and fail closed.
    $destination = @($apply.results | Where-Object status -eq 'moved')[0].destination
    Add-Content -LiteralPath $destination -Value 'tampered'
    Assert-Fails {
        & $verify -InputPath $classifiedPath -DecisionPath $decisionsPath `
            -TransactionManifestPath $manifestPath -ScanRoot $fixtureRoot -QuarantineRoot $quarantineRoot `
            -ConfigPath $configPath -OutputDirectory (Join-Path $tempRoot 'tampered-verification') -AllowLocalRoot
    } 'Verification failed'

    # Exercise the one-command workflow's date-review option without any QNAP path.
    $workflowResult = & (Join-Path $toolRoot 'run-workflow.ps1') -ConfigPath $configPath `
        -ScanRoot $fixtureRoot -IncludeDateReview -ExportOnly -AllowLocalRoot |
        Where-Object { $null -ne $_.PSObject.Properties['classifiedPath'] } | Select-Object -Last 1
    if ($null -eq $workflowResult) { throw 'Run-workflow did not return a result object.' }
    Assert-Path ([string]$workflowResult.classifiedPath) 'Workflow classified output'
    Assert-Path ([string]$workflowResult.dateReviewPath) 'Workflow date review output'
    Assert-Path ([string]$workflowResult.htmlReportPath) 'Workflow HTML report'
    Assert-Path ([string]$workflowResult.jsonReportPath) 'Workflow JSON report'

    Write-Host 'Phase 8 comprehensive PowerShell tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
