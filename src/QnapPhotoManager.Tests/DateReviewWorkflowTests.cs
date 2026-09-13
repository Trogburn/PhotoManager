using QnapPhotoManager.Models;
using QnapPhotoManager.Services;
using QnapPhotoManager.ViewModels;
using Xunit;

namespace QnapPhotoManager.Tests;

public sealed class DateReviewRowViewModelTests
{
    [Fact]
    public void ProposedItemStartsUndecidedAndMapsApproveAndSkip()
    {
        var row = NewRow("Proposed");

        Assert.True(row.IsProposed);
        Assert.False(row.HasDecision);
        Assert.False(row.IsApproved);
        Assert.Throws<InvalidOperationException>(() => row.ToDecision());

        row.Decision = "Approve";
        Assert.True(row.HasDecision);
        Assert.True(row.IsApproved);
        Assert.Equal("approve", row.ToDecision().Action);

        row.Decision = "Skip";
        Assert.True(row.HasDecision);
        Assert.False(row.IsApproved);
        Assert.Equal("skip", row.ToDecision().Action);
    }

    [Fact]
    public void NonProposedItemDefaultsToSkipAndExposesEvidenceFields()
    {
        var item = new DateReviewItem
        {
            Path = @"\\server\share\photos\2026-01-01_keep.jpg",
            Size = 339,
            Status = "Conflict",
            Confidence = "None",
            Source = "filename",
            RawValue = "2026-01-01",
            ParsedFilenameToken = "2026-01-01",
            TimezoneKind = "unspecified-local",
            TimezoneOffset = "-06:00",
            ProposedCaptureTimeUtc = "2026-01-01T06:00:00.0000000Z",
            CurrentCreationTimeUtc = "2026-09-13T06:29:22Z",
            CurrentLastWriteTimeUtc = "2026-09-13T06:29:22Z",
            Policy = "CreationTimeOnly",
            Reason = "Multiple date sources disagree."
        };
        var row = new DateReviewRowViewModel(item, () => { });

        Assert.Equal("Skip", row.Decision);
        Assert.Equal("2026-01-01_keep.jpg", row.FileName);
        Assert.Equal("339 bytes", row.SizeDescription);
        Assert.Equal("unspecified-local (-06:00)", row.TimezoneDescription);
        Assert.False(string.IsNullOrWhiteSpace(row.ProposedLocalTime));
        Assert.Equal("skip", row.ToDecision().Action);
    }

    private static DateReviewRowViewModel NewRow(string status) =>
        new(new DateReviewItem
        {
            Path = @"\\server\share\photos\file.jpg",
            Status = status,
            ProposedCaptureTimeUtc = "2026-01-01T00:00:00Z"
        }, () => { });
}

public sealed class DateReviewDecisionPolicyTests
{
    [Fact]
    public void SnapshotRequiresEveryProposedDecisionAndAtLeastOneApproval()
    {
        var first = Proposed("one.jpg");
        var second = Proposed("two.jpg");

        Assert.False(DateReviewDecisionPolicy.CanCreateSnapshot([first, second]));

        first.Decision = "Approve";
        Assert.False(DateReviewDecisionPolicy.CanCreateSnapshot([first, second]));

        second.Decision = "Skip";
        Assert.True(DateReviewDecisionPolicy.CanCreateSnapshot([first, second]));

        first.Decision = "Skip";
        Assert.False(DateReviewDecisionPolicy.HasApprovedProposal([first, second]));
        Assert.False(DateReviewDecisionPolicy.CanCreateSnapshot([first, second]));
    }

    [Fact]
    public void ApplyRequiresConfirmedSnapshotAndCompleteDecisions()
    {
        var row = Proposed("one.jpg");
        row.Decision = "Approve";
        var snapshot = new DateSnapshot("review.json", DateTimeOffset.UtcNow, []);

        Assert.False(DateReviewDecisionPolicy.CanApply(false, snapshot, [row]));
        Assert.False(DateReviewDecisionPolicy.CanApply(true, null, [row]));
        Assert.True(DateReviewDecisionPolicy.CanApply(true, snapshot, [row]));
    }

    [Fact]
    public void EmptyOrNullCollectionsAreRejected()
    {
        Assert.Throws<ArgumentNullException>(() => DateReviewDecisionPolicy.CanCreateSnapshot(null!));
        Assert.False(DateReviewDecisionPolicy.HasCompleteProposedDecisions([]));
    }

    private static DateReviewRowViewModel Proposed(string name) =>
        new(new DateReviewItem
        {
            Path = @"\\server\share\photos\" + name,
            Status = "Proposed",
            ProposedCaptureTimeUtc = "2026-01-01T00:00:00Z"
        }, () => { });
}

public sealed class MainViewModelDateWorkflowTests : TestBase
{
    [Fact]
    public void StartDateWorkMovesToDatePageWithoutDuplicateArtifacts()
    {
        var root = NewTempDirectory();
        try
        {
            var viewModel = CreateViewModel(root);
            viewModel.StartDateWorkCommand.Execute(null);
            Assert.True(SpinWait.SpinUntil(
                () => viewModel.CurrentPage == WorkflowPage.DateWork,
                TimeSpan.FromSeconds(3)));

            Assert.Equal(WorkflowPage.DateWork, viewModel.CurrentPage);
            Assert.Equal(WorkflowState.Configured, Enum.Parse<WorkflowState>(viewModel.WorkflowState));
            Assert.Contains("No duplicate workflow artifacts", viewModel.DuplicateArtifactSummary);
            Assert.False(viewModel.CreateDateSnapshotCommand.CanExecute(null));
            Assert.False(viewModel.ApplyDatesCommand.CanExecute(null));
        }
        finally { Delete(root); }
    }

    [Fact]
    public void StartDateWorkRejectsLocalScanRoot()
    {
        var root = NewTempDirectory();
        try
        {
            var viewModel = CreateViewModel(root);
            viewModel.ScanRoot = @"C:\local-test-fixture";
            viewModel.StartDateWorkCommand.Execute(null);
            Assert.True(SpinWait.SpinUntil(
                () => viewModel.StatusMessage.Contains("UNC", StringComparison.OrdinalIgnoreCase),
                TimeSpan.FromSeconds(3)));

            Assert.Equal(WorkflowPage.Configuration, viewModel.CurrentPage);
            Assert.Equal("Idle", viewModel.WorkflowState);
        }
        finally { Delete(root); }
    }

    [Fact]
    public void ResetReturnsToConfigurationAndClearsDateReview()
    {
        var root = NewTempDirectory();
        try
        {
            var viewModel = CreateViewModel(root);
            viewModel.StartDateWorkCommand.Execute(null);
            Assert.True(SpinWait.SpinUntil(
                () => viewModel.CurrentPage == WorkflowPage.DateWork,
                TimeSpan.FromSeconds(3)));
            viewModel.LoadDateReviewForTests(CreateReport(@"\\server\share\photos\one.jpg"));

            viewModel.ResetCommand.Execute(null);

            Assert.Equal(WorkflowPage.Configuration, viewModel.CurrentPage);
            Assert.Equal("Idle", viewModel.WorkflowState);
            Assert.Empty(viewModel.DateItems);
            Assert.Null(viewModel.SelectedDateItem);
            Assert.False(viewModel.CanConfirmDateSnapshot);
        }
        finally { Delete(root); }
    }

    [Fact]
    public void SnapshotAndApplyStayDisabledUntilEveryProposalIsDecided()
    {
        var root = NewTempDirectory();
        try
        {
            var viewModel = CreateViewModel(root);
            var first = @"\\server\share\photos\one.jpg";
            var second = @"\\server\share\photos\two.jpg";
            viewModel.LoadDateReviewForTests(CreateReport(first, second));

            Assert.False(viewModel.CreateDateSnapshotCommand.CanExecute(null));
            viewModel.DateItems[0].Decision = "Approve";
            Assert.False(viewModel.CreateDateSnapshotCommand.CanExecute(null));
            viewModel.DateItems[1].Decision = "Skip";
            Assert.True(viewModel.CreateDateSnapshotCommand.CanExecute(null));

            viewModel.MarkDateSnapshotForTests(new DateSnapshot("review.json", DateTimeOffset.UtcNow, []));
            Assert.True(viewModel.CanConfirmDateSnapshot);
            Assert.False(viewModel.ApplyDatesCommand.CanExecute(null));
            viewModel.DateSnapshotConfirmed = true;
            Assert.True(viewModel.ApplyDatesCommand.CanExecute(null));
        }
        finally { Delete(root); }
    }

    [Fact]
    public void SelectingADateRowBuildsAnEvidenceSummary()
    {
        var root = NewTempDirectory();
        try
        {
            var viewModel = CreateViewModel(root);
            viewModel.LoadDateReviewForTests(CreateReport(@"\\server\share\photos\missing-preview.jpg"));

            Assert.NotNull(viewModel.SelectedDateItem);
            Assert.Contains("filename", viewModel.DateEvidenceSummary, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("2026-01-01", viewModel.DateEvidenceSummary, StringComparison.Ordinal);
            Assert.Contains("Preview unavailable", viewModel.DateEvidenceSummary, StringComparison.Ordinal);
        }
        finally { Delete(root); }
    }

    private static MainViewModel CreateViewModel(string root)
    {
        var policy = new PathPolicy(root);
        var store = new AtomicArtifactStore(policy);
        return new MainViewModel(
            new WorkflowStateMachine(),
            store,
            new DateRepairService(policy),
            new DuplicateWorkflowService(new PowerShellScriptRunner(), store, policy, root),
            new FakeConfirmationService(true));
    }

    private static DateReviewReport CreateReport(params string[] paths) =>
        new()
        {
            TimezonePolicy = "Filesystem timestamps are transfer evidence only.",
            Items = paths.Select(path => new DateReviewItem
            {
                Path = path,
                Size = 339,
                Status = "Proposed",
                Confidence = "Medium",
                Source = "filename",
                RawValue = "2026-01-01",
                ParsedFilenameToken = "2026-01-01",
                TimezoneKind = "unspecified-local",
                TimezoneOffset = "-06:00",
                ProposedCaptureTimeUtc = "2026-01-01T06:00:00Z",
                CurrentCreationTimeUtc = "2026-09-13T06:29:22Z",
                CurrentLastWriteTimeUtc = "2026-09-13T06:29:22Z",
                Policy = "CreationTimeOnly",
                Reason = "Selected filename evidence over filesystem transfer timestamps."
            }).ToList()
        };
}

public sealed class FakeConfirmationService(bool result) : IConfirmationService
{
    public bool Confirm(string message, string title) => result;
}
