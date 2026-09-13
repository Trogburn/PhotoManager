[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$ClassifiedPath,

    [Parameter(Mandatory = $true)]
    [string]$DateReviewPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RelativeKey {
    param([string]$PathValue, [string]$Root)

    $normalizedPath = $PathValue.Replace('/', '\').Trim()
    $normalizedRoot = $Root.Replace('/', '\').TrimEnd('\')
    if ($normalizedPath.StartsWith("$normalizedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        $normalizedPath = $normalizedPath.Substring($normalizedRoot.Length + 1)
    }
    return $normalizedPath.TrimStart('\').ToLowerInvariant()
}

function Get-CaseMembers {
    param([object]$Case)

    $members = @()
    foreach ($member in @($Case.members)) {
        if ($member -is [string]) {
            $members += $member
        }
        elseif ($null -ne $member.path) {
            $members += [string]$member.path
        }
    }
    return @($members)
}

function Get-OptionalProperty {
    param([object]$Object, [string]$Name)

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        return $null
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Add-Check {
    param([string]$Id, [bool]$Passed, [string]$Detail)

    $script:checks += [pscustomobject]@{
        id = $Id
        passed = $Passed
        detail = $Detail
    }
}

foreach ($requiredPath in @($ManifestPath, $ClassifiedPath, $DateReviewPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required validation input was not found: $requiredPath"
    }
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$classified = Get-Content -LiteralPath $ClassifiedPath -Raw | ConvertFrom-Json
$dateReview = Get-Content -LiteralPath $DateReviewPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $classified.schemaVersion -ne 1 -or $dateReview.schemaVersion -ne 1) {
    throw 'Manifest, classified results, and date review must use schema version 1.'
}

$inputRoot = [string]$manifest.inputRoot
$checks = @()
$groups = @($classified.groups)
$groupViews = @(
    foreach ($group in $groups) {
        [pscustomobject]@{
            group = $group
            paths = @($group.items | ForEach-Object { Get-RelativeKey -PathValue ([string]$_.path) -Root $inputRoot })
        }
    }
)

foreach ($case in @($manifest.exactDuplicateGroups)) {
    $members = @($case.members | ForEach-Object { Get-RelativeKey -PathValue ([string]$_) -Root $inputRoot })
    $groupView = @($groupViews | Where-Object { $candidate = $_; @($members | Where-Object { $candidate.paths -notcontains $_ }).Count -eq 0 } | Select-Object -First 1)
    $found = $groupView.Count -eq 1
    Add-Check -Id "$($case.id):grouped" -Passed $found -Detail $(if ($found) { 'All expected exact-duplicate members share a review group.' } else { 'Expected exact-duplicate members do not share a review group.' })
    if (-not $found) { continue }

    $group = $groupView[0].group
    Add-Check -Id "$($case.id):tier" -Passed ([string]$group.confidenceTier -eq [string]$case.expectedTier) -Detail "Actual tier: $($group.confidenceTier)"
    Add-Check -Id "$($case.id):label" -Passed (@($group.labels) -contains [string]$case.expectedLabel) -Detail "Actual labels: $(@($group.labels) -join ', ')"
    $actualKeep = Get-RelativeKey -PathValue ([string]$group.suggestedKeepPath) -Root $inputRoot
    $expectedKeep = Get-RelativeKey -PathValue ([string]$case.expectedKeep) -Root $inputRoot
    Add-Check -Id "$($case.id):keeper" -Passed ($actualKeep -eq $expectedKeep) -Detail "Actual suggested keeper: $actualKeep"
}

foreach ($case in @($manifest.visualCases)) {
    $members = @(Get-CaseMembers -Case $case | ForEach-Object { Get-RelativeKey -PathValue $_ -Root $inputRoot })
    if ((Get-OptionalProperty -Object $case -Name 'mustGroupTogether') -eq $true) {
        $groupView = @($groupViews | Where-Object { $candidate = $_; @($members | Where-Object { $candidate.paths -notcontains $_ }).Count -eq 0 } | Select-Object -First 1)
        $found = $groupView.Count -eq 1
        Add-Check -Id "$($case.id):grouped" -Passed $found -Detail $(if ($found) { 'All expected visual-match members share a review group.' } else { 'Expected visual-match members do not share a review group.' })
        $allowedTiers = Get-OptionalProperty -Object $case -Name 'allowedTiers'
        if ($found -and $allowedTiers) {
            Add-Check -Id "$($case.id):tier" -Passed (@($allowedTiers) -contains [string]$groupView[0].group.confidenceTier) -Detail "Actual tier: $($groupView[0].group.confidenceTier)"
        }
        $expectedKeepValue = Get-OptionalProperty -Object $case -Name 'expectedKeep'
        if ($found -and $expectedKeepValue) {
            $actualKeep = Get-RelativeKey -PathValue ([string]$groupView[0].group.suggestedKeepPath) -Root $inputRoot
            $expectedKeep = Get-RelativeKey -PathValue ([string]$expectedKeepValue) -Root $inputRoot
            Add-Check -Id "$($case.id):keeper" -Passed ($actualKeep -eq $expectedKeep) -Detail "Actual suggested keeper: $actualKeep"
        }
    }
    if ((Get-OptionalProperty -Object $case -Name 'mustNotBeInSameReviewGroup') -eq $true) {
        $violations = @($groupViews | Where-Object { @($_.paths | Where-Object { $members -contains $_ }).Count -gt 1 })
        Add-Check -Id "$($case.id):separate" -Passed ($violations.Count -eq 0) -Detail $(if ($violations.Count -eq 0) { 'No review group contains more than one negative-control member.' } else { "Unexpected shared groups: $($violations.group.groupId -join ', ')" })
    }
}

foreach ($case in @($manifest.safetyCases)) {
    if ((Get-OptionalProperty -Object $case -Name 'mustBeDetected') -eq $true) {
        $outside = Get-RelativeKey -PathValue ([string]$case.outsidePath) -Root $inputRoot
        $protected = Get-RelativeKey -PathValue ([string]$case.protectedPath) -Root $inputRoot
        $groupView = @($groupViews | Where-Object { $_.paths -contains $outside -and $_.paths -contains $protected } | Select-Object -First 1)
        $found = $groupView.Count -eq 1
        Add-Check -Id "$($case.id):detected" -Passed $found -Detail $(if ($found) { 'Protected duplicate is visible in a review group.' } else { 'Protected duplicate was not found with its outside match.' })
        if ($found) {
            $protectedItem = @($groupView[0].group.items | Where-Object { (Get-RelativeKey -PathValue ([string]$_.path) -Root $inputRoot) -eq $protected } | Select-Object -First 1)
            Add-Check -Id "$($case.id):marked-protected" -Passed ($protectedItem.Count -eq 1 -and [bool]$protectedItem[0].protected) -Detail "Protected flag: $($protectedItem[0].protected)"
        }
    }
    if ((Get-OptionalProperty -Object $case -Name 'mustNotBeDetected') -eq $true) {
        $excluded = Get-RelativeKey -PathValue ([string]$case.excludedPath) -Root $inputRoot
        $found = @($groupViews | Where-Object { $_.paths -contains $excluded }).Count -gt 0
        Add-Check -Id "$($case.id):excluded" -Passed (-not $found) -Detail $(if ($found) { 'Excluded file appeared in a review group.' } else { 'Excluded file did not appear in any review group.' })
    }
}

$datesByPath = @{}
foreach ($item in @($dateReview.items)) {
    $datesByPath[(Get-RelativeKey -PathValue ([string]$item.path) -Root $inputRoot)] = $item
}
foreach ($case in @($manifest.dateCases)) {
    $path = Get-RelativeKey -PathValue ([string]$case.path) -Root $inputRoot
    $item = $datesByPath[$path]
    Add-Check -Id "$($case.id):present" -Passed ($null -ne $item) -Detail $(if ($item) { 'Date case appeared in review output.' } else { 'Date case is missing from review output.' })
    if ($null -eq $item) { continue }
    Add-Check -Id "$($case.id):status" -Passed ([string]$item.status -eq [string]$case.expectedStatus) -Detail "Actual status: $($item.status)"
    $expectedSource = Get-OptionalProperty -Object $case -Name 'expectedSource'
    if ($expectedSource) {
        Add-Check -Id "$($case.id):source" -Passed ([string]$item.source -eq [string]$expectedSource) -Detail "Actual source: $($item.source)"
    }
    $expectedCaptureTime = Get-OptionalProperty -Object $case -Name 'expectedCaptureTimeUtc'
    if ($expectedCaptureTime) {
        $actual = [datetimeoffset]::Parse([string]$item.proposedCaptureTimeUtc)
        $expected = [datetimeoffset]::Parse([string]$expectedCaptureTime)
        $configuredTolerance = Get-OptionalProperty -Object $case -Name 'timestampToleranceSeconds'
        $tolerance = if ($null -ne $configuredTolerance) { [double]$configuredTolerance } else { 1 }
        Add-Check -Id "$($case.id):capture-time" -Passed ([math]::Abs(($actual - $expected).TotalSeconds) -le $tolerance) -Detail "Actual capture time: $($item.proposedCaptureTimeUtc)"
    }
}

$failed = @($checks | Where-Object { -not $_.passed })
[pscustomobject]@{
    manifestPath = [IO.Path]::GetFullPath($ManifestPath)
    classifiedPath = [IO.Path]::GetFullPath($ClassifiedPath)
    dateReviewPath = [IO.Path]::GetFullPath($DateReviewPath)
    totalChecks = $checks.Count
    passedChecks = $checks.Count - $failed.Count
    failedChecks = $failed.Count
    checks = $checks
}

if ($failed.Count -gt 0) { exit 1 }
