namespace QnapPhotoManager.Services;

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

        if (!scanRoot.StartsWith(@"\\", StringComparison.Ordinal))
        {
            throw new ArgumentException("Production scan roots must be UNC paths.", nameof(scanRoot));
        }
    }

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
