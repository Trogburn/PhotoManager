namespace PhotoManager.Models;

public sealed record AppConfig
{
    public string ScanRoot { get; init; } = string.Empty;
    public string ArtifactRoot { get; init; } = "artifacts";
    public string QuarantineRoot { get; init; } = string.Empty;
    public string RepositoryRoot { get; init; } = string.Empty;
    public IReadOnlyList<string> ProtectedPaths { get; init; } = [];
    public IReadOnlyList<string> ExcludedPaths { get; init; } = [];
    public IReadOnlyList<string> PreferredDirectories { get; init; } = [];
}
