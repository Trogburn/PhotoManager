[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "qnap-phase4-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $root -ItemType Directory -Force | Out-Null
try {
    $input = Join-Path $PSScriptRoot 'fixtures\classifier-input.json'
    $outputA = Join-Path $root 'classified-a.json'
    $outputB = Join-Path $root 'classified-b.json'
    & (Join-Path $PSScriptRoot '..\classify-results.ps1') -InputPath $input -OutputPath $outputA -ConfigPath (Join-Path $PSScriptRoot '..\config.json') | Out-Null
    & (Join-Path $PSScriptRoot '..\classify-results.ps1') -InputPath $input -OutputPath $outputB -ConfigPath (Join-Path $PSScriptRoot '..\config.json') | Out-Null

    $first = Get-Content -Path $outputA -Raw
    $second = Get-Content -Path $outputB -Raw
    if ($first -ne $second) {
        throw 'Classifier output was not deterministic.'
    }

    $data = $first | ConvertFrom-Json
    if ($data.groupCount -ne 3) {
        throw "Expected 3 review groups, got $($data.groupCount)"
    }

    $exact = @($data.groups | Where-Object labels -contains 'exact duplicate')[0]
    if ($exact.confidenceTier -ne 'Very high' -or @($exact.items).Count -ne 3 -or $exact.suggestedKeepPath -ne '\\server\photos\Keep\2024-01-01-original.jpg') {
        throw 'Overlapping exact/image evidence did not merge into a Very high group with the preferred keep.'
    }
    if (@($exact.explanation.evidenceGroupIds).Count -ne 2) {
        throw 'Transitive group did not retain both original evidence group IDs.'
    }

    $thumbnail = @($data.groups | Where-Object labels -contains 'likely thumbnail')[0]
    if ($thumbnail.confidenceTier -ne 'Medium' -or @($thumbnail.labels | Where-Object { $_ -eq 'resized copy' }).Count -ne 0) {
        throw 'Thumbnail group was not distinguished from a normal resize.'
    }
    $referenceItem = @($thumbnail.items | Where-Object path -like '*Reference*')[0]
    if (-not $referenceItem.protected -or $referenceItem.advisoryAction -eq 'review') {
        throw 'Reference item was not protected from removal recommendations.'
    }

    $weak = @($data.groups | Where-Object confidenceTier -eq 'Review carefully')[0]
    if ($null -eq $weak -or @($weak.items).Count -ne 2) {
        throw 'Weak visual match was not assigned Review carefully.'
    }

    Write-Host 'Phase 4 classifier tests passed.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
