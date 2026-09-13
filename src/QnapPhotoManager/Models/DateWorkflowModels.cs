using System.Text.Json.Serialization;

namespace QnapPhotoManager.Models;

public sealed class DateReviewReport
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("generatedAtUtc")]
    public string GeneratedAtUtc { get; init; } = string.Empty;

    [JsonPropertyName("dryRun")]
    public bool DryRun { get; init; }

    [JsonPropertyName("policy")]
    public string Policy { get; init; } = string.Empty;

    [JsonPropertyName("timezonePolicy")]
    public string TimezonePolicy { get; init; } = string.Empty;

    [JsonPropertyName("futureToleranceUtc")]
    public string FutureToleranceUtc { get; init; } = string.Empty;

    [JsonPropertyName("items")]
    public List<DateReviewItem> Items { get; init; } = [];
}

public sealed class DateReviewItem
{
    [JsonPropertyName("path")]
    public string Path { get; init; } = string.Empty;

    [JsonPropertyName("size")]
    public long Size { get; init; }

    [JsonPropertyName("currentCreationTimeUtc")]
    public string CurrentCreationTimeUtc { get; init; } = string.Empty;

    [JsonPropertyName("currentLastWriteTimeUtc")]
    public string CurrentLastWriteTimeUtc { get; init; } = string.Empty;

    [JsonPropertyName("proposedCaptureTimeUtc")]
    public string? ProposedCaptureTimeUtc { get; init; }

    [JsonPropertyName("source")]
    public string? Source { get; init; }

    [JsonPropertyName("rawValue")]
    public string? RawValue { get; init; }

    [JsonPropertyName("parsedFilenameToken")]
    public string? ParsedFilenameToken { get; init; }

    [JsonPropertyName("timezoneKind")]
    public string? TimezoneKind { get; init; }

    [JsonPropertyName("timezoneOffset")]
    public string? TimezoneOffset { get; init; }

    [JsonPropertyName("confidence")]
    public string Confidence { get; init; } = "None";

    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("reason")]
    public string Reason { get; init; } = string.Empty;

    [JsonPropertyName("policy")]
    public string Policy { get; init; } = string.Empty;

    [JsonPropertyName("decisionSummary")]
    public string? DecisionSummary { get; init; }

    [JsonPropertyName("evidenceComparison")]
    public List<DateEvidenceComparison> EvidenceComparison { get; init; } = [];
}

public sealed class DateEvidenceComparison
{
    [JsonPropertyName("label")]
    public string Label { get; init; } = string.Empty;

    [JsonPropertyName("state")]
    public string State { get; init; } = string.Empty;

    [JsonPropertyName("detail")]
    public string Detail { get; init; } = string.Empty;

    [JsonPropertyName("selected")]
    public bool Selected { get; init; }
}

public sealed record DateSnapshot(
    string ReviewPath,
    DateTimeOffset CreatedUtc,
    IReadOnlyList<DateSnapshotItem> Items);

public sealed record DateSnapshotItem(
    string Path,
    long Size,
    DateTimeOffset CreationTimeUtc,
    DateTimeOffset LastWriteTimeUtc);

public sealed record DateDecision(string Path, string Action, string? Date = null);

public sealed record DateUndoEntry(
    string Path,
    DateTimeOffset BeforeCreationTimeUtc,
    DateTimeOffset BeforeLastWriteTimeUtc,
    DateTimeOffset AfterCreationTimeUtc,
    DateTimeOffset AfterLastWriteTimeUtc,
    bool VerificationPassed);

public sealed record DateApplyResult(
    string ReviewPath,
    string DecisionPath,
    string VerificationReportPath,
    string UndoManifestPath,
    int AppliedCount,
    bool VerificationPassed);
