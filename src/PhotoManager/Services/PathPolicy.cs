namespace PhotoManager.Services;

public sealed class PathPolicy(string applicationRoot)
{
    public string ApplicationRoot { get; } =
        Path.GetFullPath(applicationRoot ?? throw new ArgumentNullException(nameof(applicationRoot)));

    public string ResolveArtifactPath(string artifactRoot, string relativeName)
    {
        if (string.IsNullOrWhiteSpace(relativeName) || Path.IsPathRooted(relativeName))
        {
            throw new ArgumentException("Artifact names must be non-empty relative paths.", nameof(relativeName));
        }

        var root = Path.GetFullPath(
            Path.IsPathRooted(artifactRoot)
                ? artifactRoot
                : Path.Combine(ApplicationRoot, artifactRoot));
        var candidate = Path.GetFullPath(Path.Combine(root, relativeName));
        EnsureWithin(candidate, root);
        return candidate;
    }

    public static void ValidateScanRoot(string scanRoot)
    {
        if (string.IsNullOrWhiteSpace(scanRoot))
        {
            throw new ArgumentException("A scan root is required.", nameof(scanRoot));
        }

        var trimmed = scanRoot.Trim();
        if (trimmed.StartsWith(@"\\", StringComparison.Ordinal))
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(trimmed, @"^\\\\[^\\]+\\[^\\]+"))
            {
                throw new ArgumentException(
                    @"UNC scan roots must be a share path such as \\server\share\Photos.",
                    nameof(scanRoot));
            }

            return;
        }

        if (!Path.IsPathRooted(trimmed) || trimmed.Length < 3 || !char.IsLetter(trimmed[0]) || trimmed[1] != ':')
        {
            throw new ArgumentException(
                @"Scan roots must be a UNC path (\\server\share\Photos) or a local folder (D:\Photos).",
                nameof(scanRoot));
        }

        if (System.Text.RegularExpressions.Regex.IsMatch(trimmed, @"^[A-Za-z]:[\\/]?$"))
        {
            throw new ArgumentException(
                @"A drive root such as C:\ is not a valid scan root. Choose a folder on that drive.",
                nameof(scanRoot));
        }

        var full = Path.GetFullPath(trimmed);
        var driveRoot = Path.GetPathRoot(full);
        if (string.IsNullOrEmpty(driveRoot)
            || string.Equals(
                full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                driveRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                @"A drive root such as C:\ is not a valid scan root. Choose a folder on that drive.",
                nameof(scanRoot));
        }

        try
        {
            if (new DriveInfo(driveRoot).DriveType == DriveType.Network)
            {
                throw new ArgumentException(
                    @"Mapped network drives are not allowed. Use the UNC path (\\server\share) instead.",
                    nameof(scanRoot));
            }
        }
        catch (ArgumentException)
        {
            throw;
        }
        catch (IOException)
        {
            // Missing or unready drive letters fail later when the folder is opened.
        }
    }

    public static bool RequiresAllowLocalRoot(string scanRoot) =>
        !string.IsNullOrWhiteSpace(scanRoot)
        && !scanRoot.TrimStart().StartsWith(@"\\", StringComparison.Ordinal);

    public static bool IsWithin(string candidatePath, string parentPath)
    {
        var candidate = Path.GetFullPath(candidatePath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var parent = Path.GetFullPath(parentPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return candidate.Equals(parent, StringComparison.OrdinalIgnoreCase)
            || candidate.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static void EnsureWithin(string candidate, string root)
    {
        if (!IsWithin(candidate, root))
        {
            throw new UnauthorizedAccessException("The artifact path escapes the configured artifact root.");
        }
    }
}
