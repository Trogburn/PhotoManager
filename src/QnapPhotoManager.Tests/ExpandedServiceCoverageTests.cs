using System.Text.Json;
using QnapPhotoManager.Models;
using QnapPhotoManager.Services;
using Xunit;

namespace QnapPhotoManager.Tests;

public sealed class PathPolicyCoverageTests : TestBase
{
    [Fact]
    public void ConstructorRejectsNullAndNormalizesRoot()
    {
        Assert.Throws<ArgumentNullException>(() => new PathPolicy(null!));

        var root = NewTempDirectory();
        try
        {
            var policy = new PathPolicy(Path.Combine(root, "."));
            Assert.Equal(Path.GetFullPath(root), policy.ApplicationRoot);
        }
        finally { Delete(root); }
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData(@"C:\absolute.json")]
    public void ResolveArtifactPathRejectsInvalidNames(string name)
    {
        var root = NewTempDirectory();
        try
        {
            Assert.Throws<ArgumentException>(() =>
                new PathPolicy(root).ResolveArtifactPath("artifacts", name));
        }
        finally { Delete(root); }
    }

    [Fact]
    public void ResolveArtifactPathRejectsTraversalAndAllowsNestedRelativePath()
    {
        var root = NewTempDirectory();
        try
        {
            var policy = new PathPolicy(root);
            Assert.Throws<UnauthorizedAccessException>(() =>
                policy.ResolveArtifactPath("artifacts", @"..\outside.json"));

            var expected = Path.Combine(Path.GetFullPath(root), "artifacts", "nested", "item.json");
            Assert.Equal(expected, policy.ResolveArtifactPath("artifacts", @"nested\item.json"));
        }
        finally { Delete(root); }
    }

    [Fact]
    public void IsWithinHandlesEqualDescendantAndSiblingPaths()
    {
        var root = NewTempDirectory();
        try
        {
            Assert.True(PathPolicy.IsWithin(root, root));
            Assert.True(PathPolicy.IsWithin(Path.Combine(root, "child"), root));
            Assert.False(PathPolicy.IsWithin(root + "-sibling", root));
        }
        finally { Delete(root); }
    }
}

public sealed class AtomicArtifactStoreCoverageTests : TestBase
{
    [Fact]
    public async Task WriteReadCreatesDirectoriesAndPreservesPayload()
    {
        var root = NewTempDirectory();
        try
        {
            var store = new AtomicArtifactStore(new PathPolicy(root));
            var payload = new[] { "one", "two" };
            var path = await store.WriteAsync("artifacts", @"nested\payload.json", "test", payload);

            Assert.True(File.Exists(path));
            Assert.Equal(payload, await store.ReadAsync<string[]>("artifacts", @"nested\payload.json"));
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task WriteRejectsExistingImmutableArtifactAndLeavesOriginal()
    {
        var root = NewTempDirectory();
        try
        {
            var store = new AtomicArtifactStore(new PathPolicy(root));
            var path = await store.WriteAsync("artifacts", "immutable.json", "test", "first");
            await Assert.ThrowsAsync<IOException>(() =>
                store.WriteAsync("artifacts", "immutable.json", "test", "second"));
            Assert.Contains("first", await File.ReadAllTextAsync(path));
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ReadRejectsInvalidEnvelopeAndInvalidDigest()
    {
        var root = NewTempDirectory();
        try
        {
            var store = new AtomicArtifactStore(new PathPolicy(root));
            var policy = new PathPolicy(root);
            var invalid = policy.ResolveArtifactPath("artifacts", "invalid.json");
            Directory.CreateDirectory(Path.GetDirectoryName(invalid)!);
            await File.WriteAllTextAsync(invalid, "{not-json");
            await Assert.ThrowsAnyAsync<Exception>(() => store.ReadAsync<string>("artifacts", "invalid.json"));

            var digestPath = policy.ResolveArtifactPath("artifacts", "digest.json");
            await File.WriteAllTextAsync(digestPath,
                """{"schemaVersion":1,"artifactType":"test","createdUtc":"2026-01-01T00:00:00Z","payload":"x","payloadSha256":"not-hex"}""");
            await Assert.ThrowsAsync<InvalidDataException>(() =>
                store.ReadAsync<string>("artifacts", "digest.json"));
        }
        finally { Delete(root); }
    }
}

public sealed class WorkflowStateMachineCoverageTests : TestBase
{
    [Fact]
    public void ValidTransitionBranchesRecordHistoryAndCarryArtifacts()
    {
        var workflow = new WorkflowStateMachine();
        workflow.TransitionTo(WorkflowState.Configured, "configured");
        workflow.TransitionTo(WorkflowState.Scanning, "scan");
        workflow.TransitionTo(WorkflowState.ScanReady, "ready", "scan-dir");
        workflow.TransitionTo(WorkflowState.Reviewing, "review", reviewArtifactPath: "review.json");
        workflow.TransitionTo(WorkflowState.DateReviewReady);
        workflow.TransitionTo(WorkflowState.Reviewing);
        workflow.TransitionTo(WorkflowState.RemediationReady);
        workflow.SetSnapshotConfirmed(true);
        workflow.TransitionTo(WorkflowState.RemediationApplied);
        workflow.TransitionTo(WorkflowState.Completed);
        workflow.TransitionTo(WorkflowState.Configured);

        Assert.Equal(WorkflowState.Configured, workflow.Session.State);
        Assert.Equal(10, workflow.History.Count);
        Assert.Equal("scan-dir", workflow.Session.ScanArtifactPath);
        Assert.Equal("review.json", workflow.Session.ReviewArtifactPath);
        Assert.False(workflow.Session.SnapshotConfirmed);
        Assert.Equal("configured", workflow.History[0].Reason);
    }

    [Fact]
    public void FailedBranchSetsErrorAndCanRecover()
    {
        var workflow = new WorkflowStateMachine();
        workflow.TransitionTo(WorkflowState.Failed, "boom");
        Assert.Equal("boom", workflow.Session.Error);
        Assert.Equal(WorkflowState.Failed, workflow.History.Single().To);

        workflow.TransitionTo(WorkflowState.Configured);
        Assert.Null(workflow.Session.Error);
    }

    [Fact]
    public void InvalidTransitionsAndSnapshotConfirmationAreRejected()
    {
        var workflow = new WorkflowStateMachine();
        Assert.Throws<InvalidOperationException>(() => workflow.TransitionTo(WorkflowState.Completed));
        Assert.Throws<InvalidOperationException>(() => workflow.SetSnapshotConfirmed(true));
        workflow.TransitionTo(WorkflowState.Configured);
        Assert.Throws<InvalidOperationException>(() => workflow.TransitionTo(WorkflowState.Idle));
    }

    [Fact]
    public void SettersUpdateSessionAndResetClearsLifecycle()
    {
        var workflow = new WorkflowStateMachine();
        var artifacts = new DuplicateWorkflowArtifacts("scan", "normalized", "classified", "decisions", "review", "html", "dry");
        var updated = workflow.SetDuplicateArtifacts(artifacts);
        Assert.Same(artifacts, updated.DuplicateArtifacts);
        Assert.True(updated.UpdatedUtc >= updated.CreatedUtc);

        workflow.TransitionTo(WorkflowState.Configured);
        Assert.NotEmpty(workflow.History);
        var oldId = workflow.Session.Id;
        workflow.Reset();
        Assert.Equal(WorkflowState.Idle, workflow.Session.State);
        Assert.NotEqual(oldId, workflow.Session.Id);
        Assert.Empty(workflow.History);
        Assert.Null(workflow.Session.DuplicateArtifacts);
    }
}

public sealed class DateRepairServiceCoverageTests : TestBase
{
    [Fact]
    public async Task CreateSnapshotIncludesOnlyEligibleItemsAndWritesSnapshot()
    {
        var root = NewTempDirectory();
        try
        {
            var file = Path.Combine(root, "photo.jpg");
            await File.WriteAllTextAsync(file, "photo");
            var info = new FileInfo(file);
            var report = new DateReviewReport
            {
                Items =
                [
                    new DateReviewItem
                    {
                        Path = file, Size = info.Length, Status = "Proposed",
                        ProposedCaptureTimeUtc = "2026-01-01T00:00:00Z",
                        CurrentLastWriteTimeUtc = info.LastWriteTimeUtc.ToString("O")
                    },
                    new DateReviewItem { Path = Path.Combine(root, "skipped.jpg"), Status = "Skipped" }
                ]
            };
            var service = new DateRepairService(new PathPolicy(root));
            var snapshot = await service.CreateSnapshotAsync("review.json", report, "artifacts");

            Assert.Single(snapshot.Items);
            Assert.Equal(Path.GetFullPath(file), snapshot.Items[0].Path);
            Assert.True(File.Exists(Path.Combine(root, "artifacts", "dates", "date-snapshot.json")));
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task CreateSnapshotRejectsMissingOrStaleEligibleFiles()
    {
        var root = NewTempDirectory();
        try
        {
            var service = new DateRepairService(new PathPolicy(root));
            var missing = new DateReviewReport
            {
                Items = [new DateReviewItem
                {
                    Path = Path.Combine(root, "missing.jpg"), Size = 1, Status = "Proposed",
                    ProposedCaptureTimeUtc = "2026-01-01T00:00:00Z",
                    CurrentLastWriteTimeUtc = DateTime.UtcNow.ToString("O")
                }]
            };
            await Assert.ThrowsAsync<IOException>(() =>
                service.CreateSnapshotAsync("review", missing, "artifacts"));

            var file = Path.Combine(root, "stale.jpg");
            await File.WriteAllTextAsync(file, "actual");
            var stale = new DateReviewReport { Items = [new DateReviewItem
            {
                Path = file, Size = 999, Status = "Proposed",
                ProposedCaptureTimeUtc = "2026-01-01T00:00:00Z",
                CurrentLastWriteTimeUtc = DateTime.UtcNow.ToString("O")
            }] };
            await Assert.ThrowsAsync<IOException>(() =>
                service.CreateSnapshotAsync("review", stale, "artifacts"));
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ReadUndoEntriesSkipsBlankLinesAndUndoRejectsNoSelection()
    {
        var root = NewTempDirectory();
        try
        {
            var manifest = Path.Combine(root, "undo.jsonl");
            await File.WriteAllTextAsync(manifest,
                Environment.NewLine + """{"path":"C:\\photo.jpg","beforeCreationTimeUtc":"2026-01-01T00:00:00Z","beforeLastWriteTimeUtc":"2026-01-01T00:00:00Z","afterCreationTimeUtc":"2026-01-02T00:00:00Z","afterLastWriteTimeUtc":"2026-01-02T00:00:00Z","verificationPassed":true}""");
            var service = new DateRepairService(new PathPolicy(root));
            var entries = await service.ReadUndoEntriesAsync(manifest);
            Assert.Single(entries);
            Assert.True(entries[0].VerificationPassed);
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                service.UndoAsync(manifest, [], "artifacts"));
            Assert.Empty(await service.ReadUndoEntriesAsync(Path.Combine(root, "missing.jsonl")));
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ScanRejectsNonUncRootsBeforeInvokingPowerShell()
    {
        var root = NewTempDirectory();
        try
        {
            var service = new DateRepairService(new PathPolicy(root));
            await Assert.ThrowsAsync<ArgumentException>(() =>
                service.ScanAsync(@"C:\photos", "artifacts"));
        }
        finally { Delete(root); }
    }

    [Fact]
    public void UndoManifestPathResolvesUnderArtifactRoot()
    {
        var root = NewTempDirectory();
        try
        {
            var service = new DateRepairService(new PathPolicy(root));
            var path = service.GetUndoManifestPath("artifacts");
            Assert.Equal(Path.Combine(root, "artifacts", "dates", "date-undo.jsonl"), path);
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ApplyRejectsSnapshotForDifferentReviewBeforeProcessInvocation()
    {
        var root = NewTempDirectory();
        try
        {
            var service = new DateRepairService(new PathPolicy(root));
            var snapshot = new DateSnapshot("other-review.json", DateTimeOffset.UtcNow, []);
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                service.ApplyAsync("requested-review.json", new DateReviewReport(), snapshot, [], "artifacts"));
        }
        finally { Delete(root); }
    }
}

public sealed class DuplicateWorkflowConfigurationSafetyTests : TestBase
{
    [Fact]
    public async Task ConfigureRejectsOverlappingSourceAndQuarantineWithoutRunningScripts()
    {
        var root = NewTempDirectory();
        try
        {
            var policy = new PathPolicy(root);
            var service = new DuplicateWorkflowService(
                new PowerShellScriptRunner(),
                new AtomicArtifactStore(policy),
                policy,
                root);
            var workflow = new WorkflowStateMachine();
            await Assert.ThrowsAsync<ArgumentException>(() =>
                service.ConfigureAsync(workflow, @"\\server\share\photos", @"\\server\share\photos\quarantine", "artifacts"));
            Assert.Equal(WorkflowState.Idle, workflow.Session.State);
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ConfigureAcceptsSeparatedRootsAndPersistsConfigWithoutScripts()
    {
        var root = NewTempDirectory();
        try
        {
            var policy = new PathPolicy(root);
            var service = new DuplicateWorkflowService(
                new PowerShellScriptRunner(),
                new AtomicArtifactStore(policy),
                policy,
                root);
            var workflow = new WorkflowStateMachine();
            var config = await service.ConfigureAsync(
                workflow, @"\\server\share\photos", Path.Combine(root, "quarantine"), "artifacts");

            Assert.Equal(WorkflowState.Configured, workflow.Session.State);
            Assert.Equal(Path.GetFullPath(Path.Combine(root, "quarantine")), config.QuarantineRoot);
            var configPath = Path.Combine(root, "artifacts", "sessions", workflow.Session.Id.ToString("N"), "config.json");
            Assert.True(File.Exists(configPath));
            Assert.Contains("duplicate-session-config", await File.ReadAllTextAsync(configPath));
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ConfigureResetsCompletedAndFailedWorkflows()
    {
        var root = NewTempDirectory();
        try
        {
            var policy = new PathPolicy(root);
            var service = new DuplicateWorkflowService(new PowerShellScriptRunner(), new AtomicArtifactStore(policy), policy, root);
            foreach (var terminal in new[] { WorkflowState.Completed, WorkflowState.Failed })
            {
                var workflow = new WorkflowStateMachine();
                workflow.TransitionTo(terminal == WorkflowState.Completed ? WorkflowState.Configured : WorkflowState.Failed);
                if (terminal == WorkflowState.Completed)
                {
                    workflow.TransitionTo(WorkflowState.Scanning);
                    workflow.TransitionTo(WorkflowState.ScanReady);
                    workflow.TransitionTo(WorkflowState.Reviewing);
                    workflow.TransitionTo(WorkflowState.RemediationReady);
                    workflow.TransitionTo(WorkflowState.RemediationApplied);
                    workflow.TransitionTo(WorkflowState.Completed);
                }
                await service.ConfigureAsync(workflow, @"\\server\share\photos", Path.Combine(root, terminal.ToString()), "artifacts");
                Assert.Equal(WorkflowState.Configured, workflow.Session.State);
            }
        }
        finally { Delete(root); }
    }
}

public sealed class DuplicateReviewValidationTests : TestBase
{
    [Fact]
    public async Task ValidationRequiresEveryGroupResolutionAndIgnoresProtectionOnlyDecisions()
    {
        var root = NewTempDirectory();
        try
        {
            var classified = Path.Combine(root, "classified.json");
            var decisions = Path.Combine(root, "decisions.json");
            var first = Path.Combine(root, "first.jpg");
            var second = Path.Combine(root, "second.jpg");
            await File.WriteAllTextAsync(first, "first");
            await File.WriteAllTextAsync(second, "second");
            await File.WriteAllTextAsync(classified, JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                source = "classifier",
                groups = new[]
                {
                    new
                    {
                        groupId = "g1",
                        suggestedKeepPath = first,
                        items = new[] { new { path = first }, new { path = second } }
                    },
                    new
                    {
                        groupId = "g2",
                        suggestedKeepPath = first,
                        items = new[] { new { path = first } }
                    }
                }
            }));
            await File.WriteAllTextAsync(decisions, JsonSerializer.Serialize(new object[]
            {
                new { groupId = "g1", path = second, action = "protect", @protected = true },
                new { groupId = "g2", action = "defer" }
            }));

            var artifacts = CreateArtifacts(root, classified, decisions);
            var policy = new PathPolicy(root);
            var service = new DuplicateWorkflowService(
                new PowerShellScriptRunner(), new AtomicArtifactStore(policy), policy, root);

            var result = await service.ValidateReviewAsync(artifacts);

            Assert.False(result.IsValid);
            Assert.Equal(1, result.ResolvedGroupCount);
            Assert.Equal(2, result.TotalGroupCount);
            Assert.Equal(["g1"], result.UnresolvedGroupIds);
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ValidationAcceptsQuarantineRequestForEveryNonKeeper()
    {
        var root = NewTempDirectory();
        try
        {
            var classified = Path.Combine(root, "classified.json");
            var decisions = Path.Combine(root, "decisions.json");
            var keeper = Path.Combine(root, "keeper.jpg");
            var duplicate = Path.Combine(root, "duplicate.jpg");
            var hash = new string('a', 64);
            await File.WriteAllTextAsync(classified, JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                source = "classifier",
                groups = new[]
                {
                    new
                    {
                        groupId = "g1",
                        suggestedKeepPath = keeper,
                        items = new[] { new { path = keeper }, new { path = duplicate } }
                    }
                }
            }));
            await File.WriteAllTextAsync(decisions, JsonSerializer.Serialize(new[]
            {
                new { groupId = "g1", path = duplicate, action = "quarantine-requested", sha256 = hash }
            }));

            var artifacts = CreateArtifacts(root, classified, decisions);
            var policy = new PathPolicy(root);
            var service = new DuplicateWorkflowService(
                new PowerShellScriptRunner(), new AtomicArtifactStore(policy), policy, root);

            var result = await service.ValidateReviewAsync(artifacts);

            Assert.True(result.IsValid);
            Assert.Equal(1, result.ResolvedGroupCount);
        }
        finally { Delete(root); }
    }

    [Fact]
    public async Task ValidationAcceptsTheReviewersSingleDecisionObject()
    {
        var root = NewTempDirectory();
        try
        {
            var classified = Path.Combine(root, "classified.json");
            var decisions = Path.Combine(root, "decisions.json");
            var keeper = Path.Combine(root, "keeper.jpg");
            var duplicate = Path.Combine(root, "duplicate.jpg");
            await File.WriteAllTextAsync(classified, JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                source = "classifier",
                groups = new[] { new { groupId = "g1", suggestedKeepPath = keeper, items = new[] { new { path = keeper }, new { path = duplicate } } } }
            }));
            await File.WriteAllTextAsync(decisions, JsonSerializer.Serialize(new { groupId = "g1", action = "keep", keepPath = keeper }));

            var policy = new PathPolicy(root);
            var service = new DuplicateWorkflowService(new PowerShellScriptRunner(), new AtomicArtifactStore(policy), policy, root);
            var result = await service.ValidateReviewAsync(CreateArtifacts(root, classified, decisions));

            Assert.True(result.IsValid);
            Assert.Equal(1, result.ResolvedGroupCount);
        }
        finally { Delete(root); }
    }

    private static DuplicateWorkflowArtifacts CreateArtifacts(string root, string classified, string decisions)
    {
        var normalized = Path.Combine(root, "normalized.json");
        var review = Path.Combine(root, "review.json");
        var html = Path.Combine(root, "review.html");
        var dryRun = Path.Combine(root, "dry-run.json");
        File.WriteAllText(normalized, "{}");
        File.WriteAllText(review, "{}");
        File.WriteAllText(html, string.Empty);
        return new DuplicateWorkflowArtifacts(root, normalized, classified, decisions, review, html, dryRun);
    }
}

public abstract class TestBase
{
    protected static string NewTempDirectory() => TestDirectory.NewTempDirectory();
    protected static void Delete(string path) => TestDirectory.Delete(path);
}

internal static class TestDirectory
{
    internal static string NewTempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "QnapPhotoManager.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    internal static void Delete(string path)
    {
        if (Directory.Exists(path)) Directory.Delete(path, true);
    }
}
