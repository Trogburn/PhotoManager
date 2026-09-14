using PhotoManager.Models;

namespace PhotoManager.Services;

public sealed record DateEvidenceRow(
    string Label,
    string State,
    string Detail,
    bool IsSelected,
    bool IsMissing,
    string? Utc = null);

public sealed record DateSourceChoice(string Label, string DateValue);

public static class DateEvidencePresentation
{
    public static IReadOnlyList<DateEvidenceRow> BuildRows(DateReviewItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.EvidenceComparison is { Count: > 0 })
        {
            return item.EvidenceComparison
                .Select(row => new DateEvidenceRow(
                    row.Label,
                    row.State,
                    row.Detail,
                    row.Selected,
                    IsMissingState(row.State),
                    FirstNonEmpty(row.Utc, row.Selected ? item.ProposedCaptureTimeUtc : null)))
                .ToArray();
        }

        var source = item.Source ?? string.Empty;
        var exifSelected = source.StartsWith("exif", StringComparison.OrdinalIgnoreCase);
        var filenameSelected = source.Equals("filename", StringComparison.OrdinalIgnoreCase);
        var folderSelected = source.Equals("folder", StringComparison.OrdinalIgnoreCase);
        var filenameValue = FirstNonEmpty(item.ParsedFilenameToken, filenameSelected ? item.RawValue : null);
        var rows = new List<DateEvidenceRow>
        {
            exifSelected
                ? new DateEvidenceRow("EXIF", "Has date", item.RawValue ?? string.Empty, true, false, item.ProposedCaptureTimeUtc)
                : new DateEvidenceRow("EXIF", "Missing", "No capture date", false, true),
            filenameSelected || !string.IsNullOrWhiteSpace(filenameValue)
                ? new DateEvidenceRow(
                    "Filename",
                    "Has date",
                    filenameValue ?? item.RawValue ?? string.Empty,
                    filenameSelected,
                    false,
                    filenameSelected ? item.ProposedCaptureTimeUtc : filenameValue)
                : new DateEvidenceRow("Filename", "Missing", "No date in file name", false, true)
        };
        if (folderSelected)
        {
            rows.Add(new DateEvidenceRow("Folder", "Has date", item.RawValue ?? string.Empty, true, false, item.ProposedCaptureTimeUtc));
        }

        rows.Add(new DateEvidenceRow(
            "Filesystem",
            "Transfer only",
            $"Created {CompactDate(item.CurrentCreationTimeUtc)}; modified {CompactDate(item.CurrentLastWriteTimeUtc)}",
            false,
            false));
        return rows;
    }

    public static string BuildHeadline(DateReviewItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (!string.IsNullOrWhiteSpace(item.DecisionSummary))
        {
            return item.DecisionSummary;
        }

        var rows = BuildRows(item);
        if (item.Status.Equals("AlreadyApplied", StringComparison.OrdinalIgnoreCase))
        {
            var selectedApplied = rows.FirstOrDefault(row => row.IsSelected);
            return selectedApplied is not null && selectedApplied.State.Equals("Has date", StringComparison.OrdinalIgnoreCase)
                ? $"Already applied. {selectedApplied.Label} date ({selectedApplied.Detail}) already matches the file."
                : item.Reason;
        }

        if (item.Status.Equals("Conflict", StringComparison.OrdinalIgnoreCase))
        {
            var dated = rows
                .Where(row => row.State.Equals("Has date", StringComparison.OrdinalIgnoreCase) &&
                              !row.Label.Equals("Filesystem", StringComparison.OrdinalIgnoreCase))
                .Select(row => $"{row.Label} {row.Detail}")
                .ToArray();
            return dated.Length == 0
                ? item.Reason
                : $"Capture dates disagree: {string.Join("; ", dated)}.";
        }

        var parts = new List<string>();
        var selected = rows.FirstOrDefault(row => row.IsSelected);
        if (selected is not null && selected.State.Equals("Has date", StringComparison.OrdinalIgnoreCase))
        {
            parts.Add($"{selected.Label} has a date ({selected.Detail}).");
        }

        foreach (var row in rows.Where(row =>
                     !row.IsSelected &&
                     (row.Label is "EXIF" or "Filename" or "Folder")))
        {
            if (row.IsMissing)
            {
                parts.Add($"{row.Label} does not.");
            }
            else if (row.State.Equals("Has date", StringComparison.OrdinalIgnoreCase))
            {
                parts.Add($"{row.Label} agrees ({row.Detail}).");
            }
        }

        return parts.Count == 0 ? item.Reason : string.Join(' ', parts);
    }

    public static string EvidenceKind(DateReviewItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        var rows = BuildRows(item);
        var exif = rows.FirstOrDefault(row => row.Label.Equals("EXIF", StringComparison.OrdinalIgnoreCase));
        var filename = rows.FirstOrDefault(row => row.Label.Equals("Filename", StringComparison.OrdinalIgnoreCase));
        var source = item.Source ?? string.Empty;

        if (item.Status.Equals("Conflict", StringComparison.OrdinalIgnoreCase))
        {
            return "Dates conflict";
        }

        if (source.StartsWith("exif", StringComparison.OrdinalIgnoreCase))
        {
            if (filename?.State.Equals("Has date", StringComparison.OrdinalIgnoreCase) == true)
            {
                return "EXIF, filename agrees";
            }

            if (filename?.IsMissing == true)
            {
                return "EXIF, no filename date";
            }

            return "EXIF";
        }

        if (source.Equals("filename", StringComparison.OrdinalIgnoreCase))
        {
            if (exif?.IsMissing == true)
            {
                return "Filename, no EXIF";
            }

            if (exif?.State.Equals("Unreadable", StringComparison.OrdinalIgnoreCase) == true)
            {
                return "Filename, EXIF unreadable";
            }

            if (exif?.State.Equals("Has date", StringComparison.OrdinalIgnoreCase) == true)
            {
                return "Filename, EXIF present";
            }

            return "Filename";
        }

        if (source.Equals("folder", StringComparison.OrdinalIgnoreCase))
        {
            return "Folder name";
        }

        if (source.Equals("manual", StringComparison.OrdinalIgnoreCase))
        {
            return "Manual date";
        }

        return string.IsNullOrWhiteSpace(source) ? "No capture source" : source;
    }

    public static string StatusLabel(DateReviewItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.Status.Equals("AlreadyApplied", StringComparison.OrdinalIgnoreCase))
        {
            return "Already applied";
        }

        if (item.Status.Equals("FutureDate", StringComparison.OrdinalIgnoreCase))
        {
            return "Future date";
        }

        if (item.Status.Equals("NoEvidence", StringComparison.OrdinalIgnoreCase))
        {
            return "No dates";
        }

        if (item.Status.Equals("Conflict", StringComparison.OrdinalIgnoreCase))
        {
            return "Dates conflict";
        }

        if (item.Status.Equals("InvalidEvidence", StringComparison.OrdinalIgnoreCase))
        {
            if (Contains(item.Reason, "Impossible"))
            {
                return "Impossible date";
            }

            if (Contains(item.Reason, "month/day"))
            {
                return "Ambiguous date";
            }

            return "Invalid date";
        }

        return string.IsNullOrWhiteSpace(item.Status) ? "Unknown" : item.Status;
    }

    public static IReadOnlyList<DateSourceChoice> ChoosableSources(DateReviewItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return BuildRows(item)
            .Where(row =>
                row.State.Equals("Has date", StringComparison.OrdinalIgnoreCase) &&
                !row.Label.Equals("Filesystem", StringComparison.OrdinalIgnoreCase))
            .Select(row => new DateSourceChoice(
                row.Label,
                FirstNonEmpty(row.Utc, row.IsSelected ? item.ProposedCaptureTimeUtc : null, ParseableDate(row.Detail)) ?? string.Empty))
            .Where(choice => !string.IsNullOrWhiteSpace(choice.DateValue))
            .ToArray();
    }

    public static string CompactUtc(string? value)
    {
        if (DateTimeOffset.TryParse(value, out var parsed))
        {
            return parsed.UtcDateTime.ToString("yyyy-MM-dd HH:mm") + " UTC";
        }

        return string.IsNullOrWhiteSpace(value) ? string.Empty : value;
    }

    public static string CompactLocal(string? value)
    {
        if (DateTimeOffset.TryParse(value, out var parsed))
        {
            return parsed.ToLocalTime().ToString("g");
        }

        return string.Empty;
    }

    private static string CompactDate(string? value)
    {
        if (DateTimeOffset.TryParse(value, out var parsed))
        {
            return parsed.UtcDateTime.ToString("yyyy-MM-dd");
        }

        return string.IsNullOrWhiteSpace(value) ? "unknown" : value;
    }

    private static bool IsMissingState(string state) =>
        state.Equals("Missing", StringComparison.OrdinalIgnoreCase);

    private static string? FirstNonEmpty(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));

    private static bool Contains(string? value, string token) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Contains(token, StringComparison.OrdinalIgnoreCase);

    private static string? ParseableDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return value.Contains(':') || System.Text.RegularExpressions.Regex.IsMatch(value, @"^\d{4}-\d{2}-\d{2}")
            ? value
            : null;
    }
}
