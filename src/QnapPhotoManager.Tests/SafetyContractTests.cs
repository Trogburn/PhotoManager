using QnapPhotoManager.Models;
using QnapPhotoManager.Services;
using System.Text.Json;
using Xunit;

namespace QnapPhotoManager.Tests;

public sealed class SafetyContractTests
{
    [Theory]
    [InlineData(@"C:\Photos")]
    [InlineData("")]
    [InlineData("   ")]
    public void ProductionScanRootRejectsNonUncPaths(string value) =>
        Xunit.Assert.Throws<ArgumentException>(() => PathPolicy.ValidateScanRoot(value));

    [Fact]
    public void ProductionScanRootAcceptsUncChild() =>
        PathPolicy.ValidateScanRoot(@"\\server\share\photos");

    [Fact]
    public async Task ArtifactStoreRejectsMissingAndTamperedArtifacts()
    {
        var root = NewTempDirectory();
        try
        {
            var store = new AtomicArtifactStore(new PathPolicy(root));
            await Xunit.Assert.ThrowsAnyAsync<IOException>(() =>
                store.ReadAsync<string>("artifacts", "missing.json"));

            var path = await store.WriteAsync("artifacts", "audit.json", "test", "original");
            var original = await File.ReadAllTextAsync(path);
            await File.WriteAllTextAsync(path, original.Replace("original", "changed", StringComparison.Ordinal));
            await Xunit.Assert.ThrowsAsync<InvalidDataException>(() =>
                store.ReadAsync<string>("artifacts", "audit.json"));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void WorkflowGuardsSnapshotAndTransitions()
    {
        var workflow = new WorkflowStateMachine();
        Xunit.Assert.Throws<InvalidOperationException>(() => workflow.SetSnapshotConfirmed(true));
        workflow.TransitionTo(WorkflowState.Configured);
        workflow.TransitionTo(WorkflowState.Scanning);
        workflow.TransitionTo(WorkflowState.ScanReady);
        workflow.TransitionTo(WorkflowState.Reviewing);
        workflow.TransitionTo(WorkflowState.RemediationReady);
        workflow.SetSnapshotConfirmed(true);
        Xunit.Assert.True(workflow.Session.SnapshotConfirmed);
        workflow.TransitionTo(WorkflowState.RemediationApplied);
        workflow.TransitionTo(WorkflowState.Completed);
        Xunit.Assert.False(workflow.Session.SnapshotConfirmed);
    }

    [Theory]
    [InlineData("Proposed", "2026-01-01T00:00:00Z", true)]
    [InlineData("Conflict", "2022-01-02T09:04:05Z", true)]
    [InlineData("Skipped", "2026-01-01T00:00:00Z", false)]
    [InlineData("Proposed", null, false)]
    [InlineData("Conflict", null, false)]
    public void DateApplyCandidateRequiresProposedEvidence(string status, string? proposed, bool expected)
    {
        var item = new DateReviewItem { Status = status, ProposedCaptureTimeUtc = proposed };
        Xunit.Assert.Equal(expected, DateRepairService.IsApplyCandidate(item));
    }

    [Fact]
    public void DateReviewEvidenceFieldsDeserializeForReviewer()
    {
        const string json = """{"timezonePolicy":"naive values use local time","futureToleranceUtc":"2026-01-02T00:00:00Z","items":[{"path":"\\\\server\\share\\photo.jpg","rawValue":"20260101","parsedFilenameToken":"2026-01-01","timezoneKind":"unspecified-local","timezoneOffset":"-06:00","policy":"CreationTimeOnly","status":"Proposed"}]}""";

        var report = JsonSerializer.Deserialize<DateReviewReport>(json, new JsonSerializerOptions(JsonSerializerDefaults.Web));

        Xunit.Assert.NotNull(report);
        Xunit.Assert.Equal("naive values use local time", report!.TimezonePolicy);
        Xunit.Assert.Equal("2026-01-01", report.Items[0].ParsedFilenameToken);
        Xunit.Assert.Equal("-06:00", report.Items[0].TimezoneOffset);
        Xunit.Assert.Equal("CreationTimeOnly", report.Items[0].Policy);
    }

    private static string NewTempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }
}
