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

    $baseName = @($exact.items | Where-Object path -like '*2024-01-01-original.jpg')[0]
    if ($exact.suggestedKeepPath -ne $baseName.path) {
        throw 'Filename quality did not prefer the unsuffixed/base-quality name.'
    }
    if ($exact.items[0].path -ne $exact.suggestedKeepPath) {
        throw 'Suggested keep was not placed in the left-most item position.'
    }

    function Invoke-ClassifierDocument {
        param(
            [object]$Document,
            [object]$Config
        )
        $inputPath = Join-Path $root "$([guid]::NewGuid().ToString('N')).json"
        $outputPath = Join-Path $root "$([guid]::NewGuid().ToString('N')).classified.json"
        $configPath = Join-Path $root "$([guid]::NewGuid().ToString('N')).config.json"
        $Document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $inputPath -Encoding UTF8
        $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8
        & (Join-Path $PSScriptRoot '..\classify-results.ps1') -InputPath $inputPath -OutputPath $outputPath -ConfigPath $configPath | Out-Null
        return (Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json)
    }

    $matrixConfig = [pscustomobject]@{
        scan = [pscustomobject]@{
            protectedPaths = @('C:\photos\Protected')
            preferredDirectories = @('C:\photos\Keep')
        }
    }
    $hashBoundary = [pscustomobject]@{
        schemaVersion = 1
        groups = @(
            [pscustomobject]@{
                groupId = 'hash-case'
                source = 'czkawka'
                kind = 'similar-image'
                entries = @(
                    [pscustomobject]@{ path = 'C:\photos\Keep\A.jpg'; hash = 'ABCDEF'; size = 100; width = 1000; height = 1000; perceptualDifference = 12; isReference = $false },
                    [pscustomobject]@{ path = 'C:\photos\Other\B.jpg'; hash = 'abcdef'; size = 100; width = 1000; height = 1000; perceptualDifference = 12; isReference = $false }
                )
            }
        )
    }
    $hashResult = Invoke-ClassifierDocument -Document $hashBoundary -Config $matrixConfig
    if ($hashResult.groups[0].confidenceTier -ne 'Very high') {
        throw 'Matching hashes with case differences were not classified as Very high.'
    }

    $thresholdGroups = @()
    $thresholdCases = @(
        @{ id = 'high'; difference = 1; width = 1000; height = 500; expected = 'High' },
        @{ id = 'medium'; difference = 8; width = 1000; height = 500; expected = 'Medium' },
        @{ id = 'weak'; difference = 9; width = 1000; height = 500; expected = 'Review carefully' }
    )
    foreach ($case in $thresholdCases) {
        $thresholdGroups += [pscustomobject]@{
            groupId = $case.id
            source = 'czkawka'
            kind = 'similar-image'
            entries = @(
                [pscustomobject]@{ path = "C:\photos\$($case.id)-a.jpg"; size = 100; width = $case.width; height = $case.height; perceptualDifference = $case.difference; isReference = $false },
                [pscustomobject]@{ path = "C:\photos\$($case.id)-b.jpg"; size = 90; width = [int]($case.width / 2); height = $case.height; perceptualDifference = $case.difference; isReference = $false }
            )
        }
    }
    $thresholdResult = Invoke-ClassifierDocument -Document ([pscustomobject]@{ schemaVersion = 1; groups = $thresholdGroups }) -Config $matrixConfig
    foreach ($case in $thresholdCases) {
        $actual = @($thresholdResult.groups | Where-Object groupId -eq $null)
        $group = @($thresholdResult.groups | Where-Object { $_.items[0].path -like "*$($case.id)-a.jpg" })[0]
        if ($group.confidenceTier -ne $case.expected) {
            throw "Threshold case '$($case.id)' expected $($case.expected), got $($group.confidenceTier)."
        }
    }
    $ratioBoundary = [pscustomobject]@{
        schemaVersion = 1
        groups = @(
            [pscustomobject]@{ groupId = 'ratio-quarter'; source = 'czkawka'; kind = 'similar-image'; entries = @(
                [pscustomobject]@{ path = 'C:\photos\ratio-a.jpg'; size = 100; width = 1000; height = 1000; perceptualDifference = 2; isReference = $false },
                [pscustomobject]@{ path = 'C:\photos\ratio-b.jpg'; size = 25; width = 500; height = 500; perceptualDifference = 2; isReference = $false }
            ) },
            [pscustomobject]@{ groupId = 'ratio-nine-tenths'; source = 'czkawka'; kind = 'similar-image'; entries = @(
                [pscustomobject]@{ path = 'C:\photos\ratio-c.jpg'; size = 100; width = 1000; height = 1000; perceptualDifference = 2; isReference = $false },
                [pscustomobject]@{ path = 'C:\photos\ratio-d.jpg'; size = 90; width = 900; height = 1000; perceptualDifference = 2; isReference = $false }
            ) }
        )
    }
    $ratioResult = Invoke-ClassifierDocument -Document $ratioBoundary -Config $matrixConfig
    $quarter = @($ratioResult.groups | Where-Object { $_.items[0].path -like '*ratio-a.jpg' })[0]
    $nineTenths = @($ratioResult.groups | Where-Object { $_.items[0].path -like '*ratio-c.jpg' })[0]
    if (@($quarter.labels | Where-Object { $_ -eq 'likely thumbnail' }).Count -ne 0 -or @($quarter.labels | Where-Object { $_ -eq 'resized copy' }).Count -ne 1) {
        throw 'Quarter-area label boundary was not stable.'
    }
    if (@($nineTenths.labels | Where-Object { $_ -eq 'resized copy' }).Count -ne 0) {
        throw 'Nine-tenths-area label boundary was not stable.'
    }

    $evidenceInput = [pscustomobject]@{
        schemaVersion = 1
        groups = @(
            [pscustomobject]@{ groupId = 'evidence-dup'; source = 'dup'; kind = 'duplicate'; entries = @(
                [pscustomobject]@{ path = 'C:\photos\evidence.jpg'; size = 100; hash = 'same'; width = 1000; height = 800; isReference = $false }
            ) },
            [pscustomobject]@{ groupId = 'evidence-image'; source = 'image'; kind = 'similar-image'; entries = @(
                [pscustomobject]@{ path = 'C:\photos\evidence.jpg'; size = 100; hash = 'same'; width = 1000; height = 800; perceptualDifference = 0; isReference = $false }
            ) }
        )
    }
    $evidenceResult = Invoke-ClassifierDocument -Document $evidenceInput -Config $matrixConfig
    $evidenceGroup = $evidenceResult.groups[0]
    if ($evidenceGroup.items[0].perceptualDifference -ne 0 -or @($evidenceGroup.items[0].evidence).Count -ne 2 -or @($evidenceGroup.explanation.evidenceEdges[0].entries).Count -ne 1) {
        throw 'Classifier did not retain complete repeated-path evidence.'
    }

    $pathInput = [pscustomobject]@{
        schemaVersion = 1
        groups = @(
            [pscustomobject]@{ groupId = 'path-boundary'; source = 'duplicate'; kind = 'duplicate'; entries = @(
                [pscustomobject]@{ path = 'C:\photos\Protected2\file.jpg'; size = 200; hash = 'path'; width = 1000; height = 1000; isReference = $false },
                [pscustomobject]@{ path = 'C:\photos\Protected\file.jpg'; size = 100; hash = 'path'; width = 900; height = 900; isReference = $false }
            ) }
        )
    }
    $pathResult = Invoke-ClassifierDocument -Document $pathInput -Config $matrixConfig
    $protected2 = @($pathResult.groups[0].items | Where-Object path -like '*Protected2*')[0]
    $protected = @($pathResult.groups[0].items | Where-Object path -like '*Protected\file.jpg')[0]
    if ($protected2.protected -or -not $protected.protected -or $protected.advisoryAction -ne 'protect') {
        throw 'Protected-path boundary behavior was unsafe.'
    }

    Write-Host 'Phase 4 classifier tests passed.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
