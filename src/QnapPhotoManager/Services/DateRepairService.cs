using System.Diagnostics;
using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using QnapPhotoManager.Models;

namespace QnapPhotoManager.Services;

public sealed class DateRepairService(PathPolicy pathPolicy)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static readonly JsonSerializerOptions JsonlOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    private readonly PathPolicy _pathPolicy =
        pathPolicy ?? throw new ArgumentNullException(nameof(pathPolicy));

    public async Task<(string ReportPath, DateReviewReport Report)> ScanAsync(
        string scanRoot,
        string artifactRoot,
        CancellationToken cancellationToken = default)
    {
        PathPolicy.ValidateScanRoot(scanRoot);
        var reportPath = ResolveArtifact(artifactRoot, "dates", "date-review.json");
        Directory.CreateDirectory(Path.GetDirectoryName(reportPath)!);

        await RunPowerShellAsync(
            [
                "-File", FindScript(),
                "-Path", scanRoot,
                "-OutputPath", reportPath,
                "-Recurse"
            ],
            cancellationToken);

        return (reportPath, await ReadReportAsync(reportPath, cancellationToken));
    }

    public async Task<DateSnapshot> CreateSnapshotAsync(
        string reviewPath,
        DateReviewReport report,
        string artifactRoot,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(report);
        var items = new List<DateSnapshotItem>();
        foreach (var item in report.Items.Where(IsApplyCandidate))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = new FileInfo(item.Path);
            if (!file.Exists)
            {
                throw new IOException($"Snapshot refused; file is missing: {item.Path}");
            }

            if (file.Length != item.Size
                || !NearlyEqual(file.LastWriteTimeUtc, ParseUtc(item.CurrentLastWriteTimeUtc)))
            {
                throw new IOException($"Snapshot refused; report is stale: {item.Path}");
            }

            items.Add(new DateSnapshotItem(
                file.FullName,
                file.Length,
                file.CreationTimeUtc,
                file.LastWriteTimeUtc));
        }

        var snapshot = new DateSnapshot(reviewPath, DateTimeOffset.UtcNow, items);
        var path = ResolveArtifact(artifactRoot, "dates", "date-snapshot.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllTextAsync(
            path,
            JsonSerializer.Serialize(snapshot, JsonOptions),
            Encoding.UTF8,
            cancellationToken);
        return snapshot;
    }

    public async Task<DateApplyResult> ApplyAsync(
        string reviewPath,
        DateReviewReport report,
        DateSnapshot snapshot,
        IReadOnlyCollection<DateDecision> decisions,
        string artifactRoot,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(report);
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!string.Equals(snapshot.ReviewPath, reviewPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Apply refused; the confirmed snapshot belongs to another review report.");
        }

        ValidateSnapshot(snapshot);
        var decisionPath = ResolveArtifact(artifactRoot, "dates", "date-decisions.json");
        var verificationPath = ResolveArtifact(artifactRoot, "dates", "date-verification.json");
        var undoPath = ResolveArtifact(artifactRoot, "dates", "date-undo.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(decisionPath)!);
        await File.WriteAllTextAsync(
            decisionPath,
            JsonSerializer.Serialize(decisions, JsonOptions),
            Encoding.UTF8,
            cancellationToken);

        await RunPowerShellAsync(
            [
                "-File", FindScript(),
                "-ReviewPath", reviewPath,
                "-DecisionPath", decisionPath,
                "-OutputPath", reviewPath,
                "-UndoManifestPath", undoPath,
                "-VerificationReportPath", verificationPath,
                "-Apply"
            ],
            cancellationToken);

        var verification = await File.ReadAllTextAsync(verificationPath, cancellationToken);
        using var document = JsonDocument.Parse(verification);
        var passed = document.RootElement.TryGetProperty("passed", out var passedElement)
            && passedElement.GetBoolean();
        var appliedCount = decisions.Count(decision =>
            string.Equals(decision.Action, "approve", StringComparison.OrdinalIgnoreCase)
            || string.Equals(decision.Action, "manual", StringComparison.OrdinalIgnoreCase));
        if (!passed)
        {
            throw new IOException("Date apply completed with a failed verification report.");
        }

        ValidateAppliedTimestamps(report, decisions);

        return new DateApplyResult(
            reviewPath, decisionPath, verificationPath, undoPath, appliedCount, passed);
    }

    public async Task<IReadOnlyList<DateUndoEntry>> ReadUndoEntriesAsync(
        string manifestPath,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(manifestPath))
        {
            return [];
        }

        var entries = new List<DateUndoEntry>();
        await foreach (var line in File.ReadLinesAsync(manifestPath, cancellationToken))
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var entry = JsonSerializer.Deserialize<ManifestEntry>(line, JsonOptions);
            if (entry is not null)
            {
                entries.Add(new DateUndoEntry(
                    entry.Path,
                    ParseUtc(entry.BeforeCreationTimeUtc),
                    ParseUtc(entry.BeforeLastWriteTimeUtc),
                    ParseUtc(entry.AfterCreationTimeUtc),
                    ParseUtc(entry.AfterLastWriteTimeUtc),
                    entry.VerificationPassed));
            }
        }

        return entries;
    }

    public async Task<IReadOnlyList<DateUndoEntry>> ReadActiveUndoEntriesAsync(
        string manifestPath,
        CancellationToken cancellationToken = default)
    {
        var entries = await ReadUndoEntriesAsync(manifestPath, cancellationToken);
        return entries
            .GroupBy(entry => Path.GetFullPath(entry.Path), StringComparer.OrdinalIgnoreCase)
            .Select(group => group.Last())
            .Where(IsStillApplied)
            .ToArray();
    }

    public async Task UndoAsync(
        string manifestPath,
        IReadOnlyCollection<string> selectedPaths,
        string artifactRoot,
        CancellationToken cancellationToken = default)
    {
        var selected = selectedPaths
            .Select(Path.GetFullPath)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var selectedEntries = (await ReadActiveUndoEntriesAsync(manifestPath, cancellationToken))
            .Where(entry => selected.Contains(Path.GetFullPath(entry.Path)))
            .ToArray();
        if (selectedEntries.Length == 0)
        {
            throw new InvalidOperationException("Select at least one applied file to undo.");
        }

        var contentBefore = selectedEntries.ToDictionary(
            entry => Path.GetFullPath(entry.Path),
            entry => ReadContentEvidence(entry.Path),
            StringComparer.OrdinalIgnoreCase);
        var temporaryManifest = ResolveArtifact(
            artifactRoot, "dates", $"date-undo-selection-{Guid.NewGuid():N}.jsonl");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(temporaryManifest)!);
            var lines = selectedEntries.Select(FormatUndoManifestLine);
            await File.WriteAllLinesAsync(temporaryManifest, lines, Utf8NoBom, cancellationToken);
            await RunPowerShellAsync(
                [
                    "-File", FindScript(),
                    "-Undo",
                    "-UndoManifestPath", temporaryManifest
                ],
                cancellationToken);
        }
        finally
        {
            if (File.Exists(temporaryManifest))
            {
                File.Delete(temporaryManifest);
            }
        }

        ValidateUndoneTimestamps(selectedEntries);
        foreach (var entry in selectedEntries)
        {
            var after = ReadContentEvidence(entry.Path);
            var before = contentBefore[Path.GetFullPath(entry.Path)];
            if (after.Size != before.Size
                || !string.Equals(after.Sha256, before.Sha256, StringComparison.Ordinal))
            {
                throw new IOException($"Undo verification failed; file content changed: {entry.Path}");
            }
        }
    }

    public static bool IsApplyCandidate(DateReviewItem item) =>
        string.Equals(item.Status, "Proposed", StringComparison.OrdinalIgnoreCase)
        && !string.IsNullOrWhiteSpace(item.ProposedCaptureTimeUtc);

    public string GetUndoManifestPath(string artifactRoot) =>
        ResolveArtifact(artifactRoot, "dates", "date-undo.jsonl");

    internal static void ValidateUndoneTimestamps(IReadOnlyCollection<DateUndoEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        foreach (var entry in entries)
        {
            var file = new FileInfo(entry.Path);
            if (!file.Exists)
            {
                throw new IOException($"Undo verification failed; file is missing: {entry.Path}");
            }

            if (!NearlyEqual(file.CreationTimeUtc, entry.BeforeCreationTimeUtc.UtcDateTime))
            {
                throw new IOException(
                    $"Undo verification failed; creation time was not restored: {entry.Path}");
            }

            if (!NearlyEqual(file.LastWriteTimeUtc, entry.BeforeLastWriteTimeUtc.UtcDateTime))
            {
                throw new IOException(
                    $"Undo verification failed; last-write time was not restored: {entry.Path}");
            }
        }
    }

    internal static FileContentEvidence ReadContentEvidence(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists)
        {
            throw new IOException($"File is missing: {path}");
        }

        using var stream = info.OpenRead();
        var hash = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        return new FileContentEvidence(info.Length, hash);
    }

    internal static void ValidateAppliedTimestamps(
        DateReviewReport report,
        IReadOnlyCollection<DateDecision> decisions)
    {
        ArgumentNullException.ThrowIfNull(report);
        ArgumentNullException.ThrowIfNull(decisions);
        var approved = decisions
            .Where(decision =>
                string.Equals(decision.Action, "approve", StringComparison.OrdinalIgnoreCase)
                || string.Equals(decision.Action, "manual", StringComparison.OrdinalIgnoreCase))
            .Select(decision => Path.GetFullPath(decision.Path))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var requireLastWrite = string.Equals(
            report.Policy, "CreationAndLastWriteTime", StringComparison.OrdinalIgnoreCase);

        foreach (var item in report.Items)
        {
            if (!approved.Contains(Path.GetFullPath(item.Path)))
            {
                continue;
            }

            if (string.IsNullOrWhiteSpace(item.ProposedCaptureTimeUtc))
            {
                throw new IOException($"Apply verification failed; no proposed date: {item.Path}");
            }

            var file = new FileInfo(item.Path);
            if (!file.Exists)
            {
                throw new IOException($"Apply verification failed; file is missing: {item.Path}");
            }

            var proposed = ParseUtc(item.ProposedCaptureTimeUtc);
            if (!NearlyEqual(file.CreationTimeUtc, proposed))
            {
                throw new IOException(
                    $"Apply verification failed; creation time was not set to the proposed date: {item.Path}");
            }

            if (requireLastWrite && !NearlyEqual(file.LastWriteTimeUtc, proposed))
            {
                throw new IOException(
                    $"Apply verification failed; last-write time was not set to the proposed date: {item.Path}");
            }
        }
    }

    private void ValidateSnapshot(DateSnapshot snapshot)
    {
        foreach (var item in snapshot.Items)
        {
            var file = new FileInfo(item.Path);
            if (!file.Exists || file.Length != item.Size
                || !NearlyEqual(file.CreationTimeUtc, item.CreationTimeUtc.UtcDateTime)
                || !NearlyEqual(file.LastWriteTimeUtc, item.LastWriteTimeUtc.UtcDateTime))
            {
                throw new IOException($"Apply refused; snapshot changed: {item.Path}");
            }
        }
    }

    private string ResolveArtifact(string artifactRoot, params string[] parts)
    {
        var relative = Path.Combine(parts);
        return _pathPolicy.ResolveArtifactPath(artifactRoot, relative);
    }

    private string FindScript()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var current = directory; current is not null; current = current.Parent)
        {
            var candidate = Path.Combine(current.FullName, "tools", "czkawka", "repair-dates.ps1");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        var workingDirectoryCandidate = Path.Combine(
            Directory.GetCurrentDirectory(), "tools", "czkawka", "repair-dates.ps1");
        return File.Exists(workingDirectoryCandidate)
            ? workingDirectoryCandidate
            : throw new FileNotFoundException("The date repair script could not be located.");
    }

    private static async Task<DateReviewReport> ReadReportAsync(
        string reportPath,
        CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(reportPath);
        return await JsonSerializer.DeserializeAsync<DateReviewReport>(
            stream, JsonOptions, cancellationToken)
            ?? throw new InvalidDataException("The date review report was empty.");
    }

    private static async Task RunPowerShellAsync(
        IReadOnlyList<string> scriptArguments,
        CancellationToken cancellationToken)
    {
        Exception? lastStartException = null;
        foreach (var executable in new[] { "pwsh", "powershell" })
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = executable,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                }
            };
            process.StartInfo.ArgumentList.Add("-NoLogo");
            process.StartInfo.ArgumentList.Add("-NoProfile");
            process.StartInfo.ArgumentList.Add("-NonInteractive");
            process.StartInfo.ArgumentList.Add("-ExecutionPolicy");
            process.StartInfo.ArgumentList.Add("Bypass");
            foreach (var argument in scriptArguments)
            {
                process.StartInfo.ArgumentList.Add(argument);
            }

            try
            {
                if (!process.Start())
                {
                    throw new InvalidOperationException($"Unable to start {executable}.");
                }
            }
            catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
            {
                lastStartException = exception;
                continue;
            }

            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var output = await outputTask;
            var error = await errorTask;
            if (process.ExitCode is not 0 and not 11)
            {
                throw new InvalidOperationException(
                    $"Date repair script failed with exit code {process.ExitCode}: {error.Trim()}");
            }

            return;
        }

        throw new InvalidOperationException(
            "Neither pwsh nor Windows PowerShell could be started.", lastStartException);
    }

    internal static string FormatUndoManifestLine(DateUndoEntry entry) =>
        JsonSerializer.Serialize(
            new
            {
                path = entry.Path,
                beforeCreationTimeUtc = entry.BeforeCreationTimeUtc.ToString("o"),
                beforeLastWriteTimeUtc = entry.BeforeLastWriteTimeUtc.ToString("o"),
                afterCreationTimeUtc = entry.AfterCreationTimeUtc.ToString("o"),
                afterLastWriteTimeUtc = entry.AfterLastWriteTimeUtc.ToString("o"),
                verificationPassed = entry.VerificationPassed
            },
            JsonlOptions);

    private static bool IsStillApplied(DateUndoEntry entry)
    {
        try
        {
            var file = new FileInfo(entry.Path);
            return file.Exists
                && NearlyEqual(file.CreationTimeUtc, entry.AfterCreationTimeUtc.UtcDateTime)
                && NearlyEqual(file.LastWriteTimeUtc, entry.AfterLastWriteTimeUtc.UtcDateTime);
        }
        catch (IOException)
        {
            return false;
        }
    }

    private static DateTime ParseUtc(string value) =>
        DateTime.Parse(value, null, System.Globalization.DateTimeStyles.RoundtripKind).ToUniversalTime();

    private static bool NearlyEqual(DateTime actual, DateTime expected) =>
        Math.Abs((actual.ToUniversalTime() - expected.ToUniversalTime()).TotalSeconds) <= 1;

    internal readonly record struct FileContentEvidence(long Size, string Sha256);

    private sealed class ManifestEntry
    {
        [JsonPropertyName("path")]
        public string Path { get; init; } = string.Empty;
        [JsonPropertyName("beforeCreationTimeUtc")]
        public string BeforeCreationTimeUtc { get; init; } = string.Empty;
        [JsonPropertyName("beforeLastWriteTimeUtc")]
        public string BeforeLastWriteTimeUtc { get; init; } = string.Empty;
        [JsonPropertyName("afterCreationTimeUtc")]
        public string AfterCreationTimeUtc { get; init; } = string.Empty;
        [JsonPropertyName("afterLastWriteTimeUtc")]
        public string AfterLastWriteTimeUtc { get; init; } = string.Empty;
        [JsonPropertyName("verificationPassed")]
        public bool VerificationPassed { get; init; }
    }
}
