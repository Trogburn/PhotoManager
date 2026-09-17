using System.Security.Cryptography;
using PhotoManager.Models;
using PhotoManager.Services;
using PhotoManager.ViewModels;
using Xunit;
using Xunit.Abstractions;

namespace PhotoManager.Tests;

public sealed class LiveRotateApplyLabTests(ITestOutputHelper output)
{
    [Fact(Timeout = 180_000)]
    [Trait("Category", "Lab")]
    public async Task FinePixCopiesApplyUndoThroughRotateWorkflow()
    {
        if (Environment.GetEnvironmentVariable("PHOTO_LAB_TESTS") != "1")
        {
            return;
        }

        var source = new[]
        {
            @"\\192.168.86.70\PhotoWorkflowTest\RealPhotoSample\Input",
            @"\\TrogQNAP6HDD\PhotoWorkflowTest\RealPhotoSample\Input"
        }.FirstOrDefault(Directory.Exists);
        if (source is null)
        {
            return;
        }

        var labRoot = Path.GetDirectoryName(Path.GetDirectoryName(source))
            ?? throw new InvalidOperationException("Could not resolve PhotoWorkflowTest root.");
        var work = Path.Combine(labRoot, "RotateApplyValidation", Guid.NewGuid().ToString("N"), "Input");
        var artifacts = Path.Combine(Path.GetTempPath(), "rotate-lab-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        Directory.CreateDirectory(artifacts);

        var proposedA = Path.Combine(work, "DSCF0180 2.JPG");
        var proposedB = Path.Combine(work, "DSCF0185 2.JPG");
        var miss90 = Path.Combine(work, "DSCF0184 (2).JPG");
        var miss180 = Path.Combine(work, "DSCF0186 (2).JPG");
        File.Copy(Path.Combine(source, "DSCF0180 2.JPG"), proposedA);
        File.Copy(Path.Combine(source, "DSCF0185 2.JPG"), proposedB);
        File.Copy(Path.Combine(source, "DSCF0184 (2).JPG"), miss90);
        File.Copy(Path.Combine(source, "DSCF0186 (2).JPG"), miss180);

        var before = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [proposedA] = Sha256(proposedA),
            [proposedB] = Sha256(proposedB),
            [miss90] = Sha256(miss90),
            [miss180] = Sha256(miss180)
        };

        try
        {
            var viewModel = CreateViewModel(artifacts);
            viewModel.ScanRoot = work;
            await viewModel.StartRotateWorkForTestsAsync();
            Assert.Equal(WorkflowPage.RotateWork, viewModel.CurrentPage);

            await viewModel.ScanRotationsForTestsAsync();
            Assert.Contains("Read-only orientation scan completed", viewModel.StatusMessage);
            Assert.True(viewModel.RotateItems.Count >= 4, viewModel.StatusMessage);

            var bird = Find(viewModel, "DSCF0180 2.JPG");
            var giraffe = Find(viewModel, "DSCF0185 2.JPG");
            var antelope = Find(viewModel, "DSCF0184 (2).JPG");
            var oryx = Find(viewModel, "DSCF0186 (2).JPG");
            Assert.Equal("Proposed", bird.Status);
            Assert.Equal(6, bird.Item.ProposedOrientation);
            bird.Decision = "Approve";

            Assert.Equal("Proposed", giraffe.Status);
            Assert.Equal(6, giraffe.Item.ProposedOrientation);
            giraffe.Decision = "Approve";

            Assert.Equal("AlreadyUpright", antelope.Status);
            viewModel.SelectedRotateItem = antelope;
            Assert.True(viewModel.RotateSelectedClockwiseCommand.CanExecute(null), antelope.Item.DecodeStatus);
            viewModel.RotateSelectedClockwiseCommand.Execute(null);
            Assert.True(antelope.IsApproved);
            Assert.Equal(6, antelope.Item.ProposedOrientation);

            Assert.Equal("AlreadyUpright", oryx.Status);
            viewModel.SelectedRotateItem = oryx;
            Assert.True(viewModel.RotateSelected180Command.CanExecute(null), oryx.Item.DecodeStatus);
            viewModel.RotateSelected180Command.Execute(null);
            Assert.True(oryx.IsApproved);
            Assert.Equal(3, oryx.Item.ProposedOrientation);

            Assert.True(viewModel.CreateRotateSnapshotCommand.CanExecute(null));
            Assert.False(viewModel.ApplyRotationsCommand.CanExecute(null));
            await viewModel.CreateRotateSnapshotForTestsAsync();
            Assert.Matches(@"^QPM-ROT-[0-9a-f]{8}-\d{6}-\d{6}$", viewModel.RotateSnapshotName);
            output.WriteLine("Suggested NAS snapshot name: " + viewModel.RotateSnapshotName);
            Assert.True(viewModel.CanConfirmRotateSnapshot);
            Assert.False(viewModel.ApplyRotationsCommand.CanExecute(null));

            viewModel.RotateSnapshotConfirmed = true;
            Assert.True(viewModel.ApplyRotationsCommand.CanExecute(null));
            await viewModel.ApplyRotationsForTestsAsync();
            Assert.Contains("Rotated 4 file(s)", viewModel.StatusMessage);
            Assert.Equal(WorkflowPage.RotateUndo, viewModel.CurrentPage);

            foreach (var path in before.Keys)
            {
                Assert.NotEqual(before[path], Sha256(path));
            }

            var backups = Directory.GetFiles(Path.Combine(artifacts, "rotate", "backups"));
            Assert.Equal(4, backups.Length);

            viewModel.SelectAllRotateUndoCommand.Execute(null);
            await viewModel.UndoSelectedForTestsAsync();
            Assert.Contains("Restored 4 original file(s)", viewModel.StatusMessage);

            foreach (var path in before.Keys)
            {
                Assert.Equal(before[path], Sha256(path));
            }
        }
        finally
        {
            try
            {
                Directory.Delete(Path.GetDirectoryName(work)!, true);
            }
            catch (IOException)
            {
            }

            try
            {
                Directory.Delete(artifacts, true);
            }
            catch (IOException)
            {
            }
        }
    }

    private static RotateReviewRowViewModel Find(MainViewModel viewModel, string fileName) =>
        viewModel.RotateItems.Single(item => string.Equals(item.FileName, fileName, StringComparison.OrdinalIgnoreCase));

    private static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static MainViewModel CreateViewModel(string root)
    {
        var policy = new PathPolicy(root);
        var store = new AtomicArtifactStore(policy);
        return new MainViewModel(
            new WorkflowStateMachine(),
            store,
            new DateRepairService(policy),
            new OrientationRepairService(policy),
            new DuplicateWorkflowService(new PowerShellScriptRunner(), store, policy, root),
            new FakeConfirmationService(true))
        {
            ArtifactRoot = root
        };
    }
}
