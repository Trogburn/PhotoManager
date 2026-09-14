using System.Text.Json;

namespace PhotoManager.Services;

public sealed record LocalDefaults
{
    public string? ScanRoot { get; init; }
    public string? QuarantineRoot { get; init; }
    public string? ArtifactRoot { get; init; }

    public static LocalDefaults? TryLoad(string configDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(configDirectory);
        var path = Path.Combine(configDirectory, "config.local.json");
        if (!File.Exists(path))
        {
            return null;
        }

        using var document = JsonDocument.Parse(File.ReadAllText(path));
        if (!document.RootElement.TryGetProperty("scan", out var scan))
        {
            return null;
        }

        return new LocalDefaults
        {
            ScanRoot = ReadString(scan, "uncRoot"),
            QuarantineRoot = ReadString(scan, "quarantineRoot"),
            ArtifactRoot = ReadString(scan, "artifactRoot")
        };
    }

    private static string? ReadString(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        var text = value.GetString();
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }
}
