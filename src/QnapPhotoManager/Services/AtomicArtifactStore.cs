using System.Text.Json;
using System.Text.Json.Serialization;
using System.Security.Cryptography;
using QnapPhotoManager.Models;

namespace QnapPhotoManager.Services;

public sealed class AtomicArtifactStore(PathPolicy pathPolicy)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly PathPolicy _pathPolicy =
        pathPolicy ?? throw new ArgumentNullException(nameof(pathPolicy));

    public async Task<string> WriteAsync<T>(
        string artifactRoot,
        string relativeName,
        string artifactType,
        T payload,
        CancellationToken cancellationToken = default)
    {
        var destination = _pathPolicy.ResolveArtifactPath(artifactRoot, relativeName);
        var directory = Path.GetDirectoryName(destination)
            ?? throw new InvalidOperationException("Artifact destination has no directory.");
        Directory.CreateDirectory(directory);

        var envelope = new ArtifactEnvelope<T>(
            SchemaVersion: 1,
            ArtifactType: artifactType,
            CreatedUtc: DateTimeOffset.UtcNow,
            Payload: payload,
            PayloadSha256: ComputePayloadHash(payload));
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";

        try
        {
            await using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 16 * 1024,
                options: FileOptions.SequentialScan | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, envelope, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }

            if (File.Exists(destination))
            {
                throw new IOException($"Artifact already exists and is immutable: {destination}");
            }

            File.Move(temporary, destination);
            return destination;
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    public async Task<T> ReadAsync<T>(
        string artifactRoot,
        string relativeName,
        CancellationToken cancellationToken = default)
    {
        var path = _pathPolicy.ResolveArtifactPath(artifactRoot, relativeName);
        await using var stream = File.OpenRead(path);
        var envelope = await JsonSerializer.DeserializeAsync<ArtifactEnvelope<T>>(
            stream, JsonOptions, cancellationToken);
        if (envelope is null)
        {
            throw new InvalidDataException("Artifact is empty or invalid.");
        }

        if (envelope.PayloadSha256 is not null)
        {
            try
            {
                var expected = Convert.FromHexString(envelope.PayloadSha256);
                var actual = Convert.FromHexString(ComputePayloadHash(envelope.Payload));
                if (!CryptographicOperations.FixedTimeEquals(expected, actual))
                {
                    throw new InvalidDataException("Artifact payload integrity check failed.");
                }
            }
            catch (FormatException exception)
            {
                throw new InvalidDataException("Artifact payload integrity digest is invalid.", exception);
            }
        }

        return envelope.Payload;
    }

    private static string ComputePayloadHash<T>(T payload)
    {
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        return Convert.ToHexString(SHA256.HashData(payloadBytes));
    }
}
