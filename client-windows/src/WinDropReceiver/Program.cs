using System.Globalization;
using System.IO.Compression;

var options = ReceiverOptions.Parse(args);
Directory.CreateDirectory(options.OutputDirectory);

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.Limits.MaxRequestBodySize = null;
});
builder.WebHost.UseUrls(options.ListenUrl);
var app = builder.Build();

app.MapGet("/health", (HttpRequest request) =>
{
    if (!options.TokenAccepted(request))
    {
        return Results.Unauthorized();
    }
    return Results.Json(new
    {
        status = "ok",
        app = "UniDrop",
        platform = "windows",
        receiver = ReceiverInfo.DisplayName,
        version = ReceiverInfo.Version,
        supportedContentTypes = ReceiverInfo.SupportedContentTypes,
        outputDirectory = options.OutputDirectory
    });
});

app.MapPost("/api/transfers/archive", async (HttpRequest request) =>
{
    if (!options.TokenAccepted(request))
    {
        return Results.Unauthorized();
    }
    var contentType = request.ContentType?.Split(';', 2)[0].Trim().ToLowerInvariant();
    if (!ReceiverInfo.SupportedContentTypes.Contains(contentType))
    {
        return Results.Json(
            new
            {
                error = "unsupported_media_type",
                receivedContentType = request.ContentType,
                normalizedContentType = contentType,
                supportedContentTypes = ReceiverInfo.SupportedContentTypes,
                version = ReceiverInfo.Version
            },
            statusCode: StatusCodes.Status415UnsupportedMediaType
        );
    }

    var transferId = Guid.NewGuid().ToString("N");
    var extension = contentType == "application/x-dvzip" ? "dvzip" : "cpio";
    var tempPath = Path.Combine(Path.GetTempPath(), $"windrop-{transferId}.{extension}");
    CopyResult copyResult;
    await using (var tempFile = File.Create(tempPath))
    {
        copyResult = await BodyCopy.CopyWithIdleTimeoutAsync(request.Body, tempFile, request.HttpContext.RequestAborted);
    }

    if (!copyResult.Completed)
    {
        BodyCopy.TryDelete(tempPath);
        Console.WriteLine($"Upload stopped before a complete archive arrived: {copyResult.Reason}, bytes={copyResult.BytesWritten}");
        return Results.Json(new
        {
            status = "failed",
            error = copyResult.Reason,
            bytesReceived = copyResult.BytesWritten,
            version = ReceiverInfo.Version
        }, statusCode: StatusCodes.Status408RequestTimeout);
    }

    try
    {
        await using var archive = File.OpenRead(tempPath);
        var extracted = TransferExtractor.Extract(contentType, archive, options.OutputDirectory);
        return Results.Json(new
        {
            status = "saved",
            transferId,
            contentType,
            files = extracted
        });
    }
    catch (Exception ex) when (ex is InvalidDataException or IOException)
    {
        Console.WriteLine($"Upload archive rejected quickly: {ex.Message}");
        return Results.Json(new
        {
            status = "failed",
            error = "invalid_archive",
            message = ex.Message,
            version = ReceiverInfo.Version
        }, statusCode: StatusCodes.Status400BadRequest);
    }
    finally
    {
        BodyCopy.TryDelete(tempPath);
    }
});

Console.WriteLine($"UniDrop Windows Receiver listening on {options.ListenUrl}");
Console.WriteLine($"Saving files to {options.OutputDirectory}");
Console.WriteLine(options.PairingToken is null
    ? "Pairing token: disabled for local MVP"
    : "Pairing token: required");
await app.RunAsync();

static class ReceiverInfo
{
    public const string Version = "0.4.1-large-upload-kestrel";
    public static readonly string DisplayName = Environment.MachineName;
    public static readonly TimeSpan UploadIdleTimeout = TimeSpan.FromSeconds(15);
    public static readonly string[] SupportedContentTypes =
    [
        "application/x-cpio",
        "application/x-dvzip"
    ];
}

static class BodyCopy
{
    public static async Task<CopyResult> CopyWithIdleTimeoutAsync(
        Stream source,
        Stream destination,
        CancellationToken requestAborted)
    {
        var buffer = new byte[64 * 1024];
        long bytesWritten = 0;

        while (true)
        {
            using var idleCts = CancellationTokenSource.CreateLinkedTokenSource(requestAborted);
            idleCts.CancelAfter(ReceiverInfo.UploadIdleTimeout);
            try
            {
                var bytesRead = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), idleCts.Token);
                if (bytesRead == 0)
                {
                    return new CopyResult(true, bytesWritten, null);
                }

                await destination.WriteAsync(buffer.AsMemory(0, bytesRead), requestAborted);
                bytesWritten += bytesRead;
            }
            catch (OperationCanceledException)
            {
                return new CopyResult(
                    false,
                    bytesWritten,
                    requestAborted.IsCancellationRequested ? "request_aborted" : "upload_idle_timeout"
                );
            }
            catch (Microsoft.AspNetCore.Http.BadHttpRequestException ex)
            {
                return new CopyResult(false, bytesWritten, ex.Message);
            }
            catch (IOException ex)
            {
                return new CopyResult(false, bytesWritten, ex.Message);
            }
        }
    }

    public static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best effort cleanup only.
        }
    }
}

readonly record struct CopyResult(bool Completed, long BytesWritten, string? Reason);

static class TransferExtractor
{
    public static IReadOnlyList<string> Extract(string? contentType, Stream archive, string outputDirectory)
    {
        var stagingDirectory = Path.Combine(Path.GetTempPath(), $"windrop-extract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(stagingDirectory);
        try
        {
            var staged = contentType == "application/x-dvzip"
                ? DvZipExtractor.Extract(archive, stagingDirectory)
                : CpioExtractor.Extract(archive, stagingDirectory);

            var moved = new List<string>();
            foreach (var stagedPath in staged)
            {
                if (!File.Exists(stagedPath))
                {
                    continue;
                }

                RepairKnownOneByteImageShift(stagedPath);
                var destination = UniquePath(Path.Combine(outputDirectory, Path.GetFileName(stagedPath)));
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Move(stagedPath, destination);
                moved.Add(destination);
            }
            return moved;
        }
        finally
        {
            Directory.Delete(stagingDirectory, recursive: true);
        }
    }

    private static string UniquePath(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path))
        {
            return path;
        }
        var directory = Path.GetDirectoryName(path)!;
        var name = Path.GetFileNameWithoutExtension(path);
        var extension = Path.GetExtension(path);
        for (var index = 1; ; index++)
        {
            var candidate = Path.Combine(directory, $"{name} ({index}){extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
    }

    private static void RepairKnownOneByteImageShift(string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length < 4)
        {
            return;
        }

        byte? missingFirstByte = extension switch
        {
            ".png" when LooksLikePngShiftedLeft(bytes) => 0x89,
            ".jpg" or ".jpeg" when LooksLikeJpegShiftedLeft(bytes) => 0xff,
            _ => null,
        };
        if (missingFirstByte is null)
        {
            return;
        }

        var repaired = new byte[bytes.Length];
        repaired[0] = missingFirstByte.Value;
        Array.Copy(bytes, 0, repaired, 1, bytes.Length - 1);
        File.WriteAllBytes(path, repaired);
        Console.WriteLine($"Repaired one-byte shifted image payload: {Path.GetFileName(path)}");
    }

    private static bool LooksLikePngShiftedLeft(byte[] bytes)
    {
        return bytes.Length >= 8
            && bytes[0] == 0x50 && bytes[1] == 0x4e && bytes[2] == 0x47
            && bytes[3] == 0x0d && bytes[4] == 0x0a && bytes[5] == 0x1a
            && bytes[6] == 0x0a && bytes[7] == 0x00;
    }

    private static bool LooksLikeJpegShiftedLeft(byte[] bytes)
    {
        return bytes.Length >= 3 && bytes[0] == 0xd8 && bytes[1] == 0xff;
    }
}

sealed record ReceiverOptions(string ListenUrl, string OutputDirectory, string? PairingToken)
{
    public static ReceiverOptions Parse(string[] args)
    {
        var listen = Environment.GetEnvironmentVariable("WINDROP_LISTEN_URL") ?? "http://0.0.0.0:8873";
        var output = Environment.GetEnvironmentVariable("WINDROP_OUTPUT_DIR")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "UniDrop");
        var token = Environment.GetEnvironmentVariable("WINDROP_PAIRING_TOKEN");

        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--listen" when index + 1 < args.Length:
                    listen = args[++index];
                    break;
                case "--out" when index + 1 < args.Length:
                    output = args[++index];
                    break;
                case "--token" when index + 1 < args.Length:
                    token = args[++index];
                    break;
            }
        }

        return new ReceiverOptions(listen, Path.GetFullPath(output), string.IsNullOrWhiteSpace(token) ? null : token);
    }

    public bool TokenAccepted(HttpRequest request)
    {
        if (PairingToken is null)
        {
            return true;
        }
        return request.Headers.TryGetValue("X-WinDrop-Token", out var value)
            && string.Equals(value.ToString(), PairingToken, StringComparison.Ordinal);
    }
}

static class CpioExtractor
{
    public static IReadOnlyList<string> Extract(Stream archiveStream, string outputDirectory)
    {
        using var buffered = new BufferedStream(archiveStream, 128 * 1024);
        using var payload = OpenPossiblyGzip(buffered);
        var extracted = new List<string>();

        while (true)
        {
            var magic = ReadText(payload, 6);
            if (magic.Length == 0)
            {
                break;
            }

            var entry = magic switch
            {
                "070701" or "070702" => ReadNewAsciiEntry(payload),
                "070707" => ReadOldAsciiEntry(payload),
                _ when extracted.Count > 0 => null,
                _ => throw new InvalidDataException($"Unsupported CPIO magic {magic}")
            };
            if (entry is null)
            {
                Console.WriteLine($"Ignoring trailing CPIO data after {extracted.Count} extracted file(s): magic={magic}");
                break;
            }

            if (entry.Name == "TRAILER!!!")
            {
                break;
            }

            var safeName = SafeFileName(entry.Name);
            if (safeName.Length == 0 || entry.IsDirectory)
            {
                SkipExactly(payload, entry.Size, entry.DataPadding);
                continue;
            }

            var destination = UniquePath(Path.Combine(outputDirectory, safeName));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using (var output = File.Create(destination))
            {
                CopyExactly(payload, output, entry.Size);
            }
            SkipExactly(payload, 0, entry.DataPadding);
            extracted.Add(destination);
        }

        return extracted;
    }

    private static Stream OpenPossiblyGzip(BufferedStream stream)
    {
        var first = stream.ReadByte();
        var second = stream.ReadByte();
        if (first < 0 || second < 0)
        {
            throw new InvalidDataException("Archive is empty");
        }
        var prefixed = new PrefixStream(new[] { (byte)first, (byte)second }, stream);
        if (first == 0x1f && second == 0x8b)
        {
            return new GZipStream(prefixed, CompressionMode.Decompress);
        }
        if (stream.CanSeek)
        {
            stream.Position -= 2;
            return stream;
        }
        return prefixed;
    }

    private static CpioEntry ReadNewAsciiEntry(Stream stream)
    {
        var fields = new string[13];
        for (var index = 0; index < fields.Length; index++)
        {
            fields[index] = ReadText(stream, 8);
        }
        var mode = ParseHex(fields[1]);
        var size = ParseHex(fields[6]);
        var nameSize = ParseHex(fields[11]);
        var name = ReadName(stream, nameSize);
        var namePadding = ChooseNewAsciiNamePadding(stream, name, size, Pad4(110 + nameSize));
        if (namePadding >= 0)
        {
            SkipExactly(stream, 0, namePadding);
        }
        else
        {
            stream.Position += namePadding;
        }
        return new CpioEntry(name, size, (mode & 0x4000) == 0x4000, Pad4(size));
    }

    private static CpioEntry ReadOldAsciiEntry(Stream stream)
    {
        _ = ReadText(stream, 6);
        _ = ReadText(stream, 6);
        var mode = ParseOctal(ReadText(stream, 6));
        _ = ReadText(stream, 6);
        _ = ReadText(stream, 6);
        _ = ReadText(stream, 6);
        _ = ReadText(stream, 6);
        _ = ReadText(stream, 11);
        var nameSize = ParseOctal(ReadText(stream, 6));
        var size = ParseOctal(ReadText(stream, 11));
        var name = ReadName(stream, nameSize);
        SkipExactly(stream, 0, (76 + nameSize) % 2);
        return new CpioEntry(name, size, (mode & 0x4000) == 0x4000, size % 2);
    }

    private static string ReadName(Stream stream, long size)
    {
        var bytes = new byte[size];
        stream.ReadExactly(bytes);
        if (bytes.Length > 0 && bytes[^1] == 0)
        {
            bytes = bytes[..^1];
        }
        else if (bytes.Length > 0 && stream.CanSeek)
        {
            stream.Position -= 1;
            bytes = bytes[..^1];
        }
        return System.Text.Encoding.UTF8.GetString(bytes);
    }

    private static string ReadText(Stream stream, int size)
    {
        var bytes = new byte[size];
        var offset = 0;
        while (offset < size)
        {
            var read = stream.Read(bytes, offset, size - offset);
            if (read == 0)
            {
                if (offset == 0)
                {
                    return "";
                }
                throw new EndOfStreamException();
            }
            offset += read;
        }
        return System.Text.Encoding.ASCII.GetString(bytes);
    }

    private static long ChooseNewAsciiNamePadding(Stream stream, string name, long entrySize, long standardPadding)
    {
        if (!stream.CanSeek)
        {
            return standardPadding;
        }

        var dataStart = stream.Position;
        var candidates = standardPadding == 0 ? [0L, -1L] : new[] { standardPadding, 0L, -1L };
        var bestPadding = standardPadding;
        var bestScore = -1;
        foreach (var candidate in candidates)
        {
            var score = 0;
            if (FileDataLooksValid(stream, name, dataStart + candidate))
            {
                score += 4;
            }
            if (NextMagicLooksValid(stream, dataStart + candidate + entrySize + Pad4(entrySize)))
            {
                score += 2;
            }
            if (candidate == standardPadding)
            {
                score += 1;
            }

            if (score > bestScore)
            {
                bestScore = score;
                bestPadding = candidate;
            }
        }

        stream.Position = dataStart;
        return bestPadding;
    }

    private static bool FileDataLooksValid(Stream stream, string name, long position)
    {
        if (position < 0 || position >= stream.Length)
        {
            return false;
        }

        var originalPosition = stream.Position;
        try
        {
            stream.Position = position;
            Span<byte> header = stackalloc byte[16];
            var read = stream.Read(header);
            if (LooksLikeKnownFileSignature(header, read))
            {
                return true;
            }

            var extension = Path.GetExtension(name).TrimEnd('\ufffd', '\0').ToLowerInvariant();
            return extension switch
            {
                ".jpg" or ".jpeg" => read >= 2 && header[0] == 0xff && header[1] == 0xd8,
                ".png" => read >= 8
                    && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4e && header[3] == 0x47
                    && header[4] == 0x0d && header[5] == 0x0a && header[6] == 0x1a && header[7] == 0x0a,
                ".gif" => read >= 6 && System.Text.Encoding.ASCII.GetString(header[..6]) is "GIF87a" or "GIF89a",
                ".heic" or ".heif" => read >= 12 && System.Text.Encoding.ASCII.GetString(header[4..12]).StartsWith("ftyp", StringComparison.Ordinal),
                _ => false,
            };
        }
        finally
        {
            stream.Position = originalPosition;
        }
    }

    private static bool LooksLikeKnownFileSignature(Span<byte> header, int read)
    {
        return read >= 2 && header[0] == 0xff && header[1] == 0xd8
            || read >= 8
                && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4e && header[3] == 0x47
                && header[4] == 0x0d && header[5] == 0x0a && header[6] == 0x1a && header[7] == 0x0a
            || read >= 6 && System.Text.Encoding.ASCII.GetString(header[..6]) is "GIF87a" or "GIF89a"
            || read >= 12 && System.Text.Encoding.ASCII.GetString(header[4..8]) == "ftyp";
    }

    private static bool NextMagicLooksValid(Stream stream, long position)
    {
        if (position < 0 || position > stream.Length)
        {
            return false;
        }

        var originalPosition = stream.Position;
        try
        {
            stream.Position = position;
            Span<byte> magicBytes = stackalloc byte[6];
            var read = stream.Read(magicBytes);
            if (read == 0)
            {
                return true;
            }
            if (read != magicBytes.Length)
            {
                return false;
            }
            return System.Text.Encoding.ASCII.GetString(magicBytes) is "070701" or "070702" or "070707";
        }
        finally
        {
            stream.Position = originalPosition;
        }
    }

    private static long ParseHex(string value) => long.Parse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);

    private static long ParseOctal(string value) => Convert.ToInt64(value.Trim(), 8);

    private static long Pad4(long value) => (4 - value % 4) % 4;

    private static string SafeFileName(string name)
    {
        var fileName = Path.GetFileName(name.Replace('\\', '/'));
        foreach (var invalid in Path.GetInvalidFileNameChars())
        {
            fileName = fileName.Replace(invalid, '_');
        }
        return fileName;
    }

    private static string UniquePath(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path))
        {
            return path;
        }
        var directory = Path.GetDirectoryName(path)!;
        var name = Path.GetFileNameWithoutExtension(path);
        var extension = Path.GetExtension(path);
        for (var index = 1; ; index++)
        {
            var candidate = Path.Combine(directory, $"{name} ({index}){extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
    }

    private static void CopyExactly(Stream input, Stream output, long bytes)
    {
        var buffer = new byte[128 * 1024];
        while (bytes > 0)
        {
            var read = input.Read(buffer, 0, (int)Math.Min(buffer.Length, bytes));
            if (read == 0)
            {
                throw new EndOfStreamException();
            }
            output.Write(buffer, 0, read);
            bytes -= read;
        }
    }

    private static void SkipExactly(Stream stream, long bytes, long padding)
    {
        var remaining = bytes + padding;
        var buffer = new byte[8192];
        while (remaining > 0)
        {
            var read = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
            if (read == 0)
            {
                throw new EndOfStreamException();
            }
            remaining -= read;
        }
    }

    sealed record CpioEntry(string Name, long Size, bool IsDirectory, long DataPadding);

    sealed class PrefixStream(byte[] prefix, Stream inner) : Stream
    {
        private int position;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (position < prefix.Length)
            {
                var copied = Math.Min(count, prefix.Length - position);
                Array.Copy(prefix, position, buffer, offset, copied);
                position += copied;
                return copied;
            }
            return inner.Read(buffer, offset, count);
        }
    }
}

static class DvZipExtractor
{
    public static IReadOnlyList<string> Extract(Stream archiveStream, string outputDirectory)
    {
        if (LooksLikeCpioOrGzip(archiveStream))
        {
            return CpioExtractor.Extract(archiveStream, outputDirectory);
        }

        var tempPath = Path.Combine(Path.GetTempPath(), $"windrop-dvzip-expanded-{Guid.NewGuid():N}.cpio");
        try
        {
            using (var decompressed = File.Create(tempPath))
            {
                DecompressChunks(archiveStream, decompressed);
            }

            using var cpio = File.OpenRead(tempPath);
            return CpioExtractor.Extract(cpio, outputDirectory);
        }
        finally
        {
            File.Delete(tempPath);
        }
    }

    private static bool LooksLikeCpioOrGzip(Stream stream)
    {
        if (!stream.CanSeek)
        {
            return false;
        }

        var originalPosition = stream.Position;
        Span<byte> header = stackalloc byte[6];
        var read = stream.Read(header);
        stream.Position = originalPosition;
        return read >= 2 && header[0] == 0x1f && header[1] == 0x8b
            || read >= 6 && System.Text.Encoding.ASCII.GetString(header) is "070701" or "070702" or "070707";
    }

    private static void DecompressChunks(Stream input, Stream output)
    {
        Span<byte> lengthBytes = stackalloc byte[4];
        while (true)
        {
            var lengthRead = ReadAtMost(input, lengthBytes);
            if (lengthRead == 0)
            {
                break;
            }
            if (lengthRead != lengthBytes.Length)
            {
                throw new EndOfStreamException("Incomplete DVZip chunk length.");
            }

            var compressedLength = ParseDvZipChunkLength(lengthBytes);
            if (compressedLength == 0)
            {
                break;
            }
            if (compressedLength < 0)
            {
                throw new InvalidDataException($"Invalid DVZip chunk length {compressedLength}.");
            }

            using var chunk = new LimitedReadStream(input, compressedLength);
            using (var zlib = new ZLibStream(chunk, CompressionMode.Decompress, leaveOpen: false))
            {
                zlib.CopyTo(output);
            }
            if (chunk.Remaining != 0)
            {
                throw new InvalidDataException("DVZip chunk ended before the advertised compressed length was consumed.");
            }
        }
        output.Position = 0;
    }

    private static int ParseDvZipChunkLength(ReadOnlySpan<byte> lengthBytes)
    {
        var bigEndian =
            lengthBytes[0] << 24
            | lengthBytes[1] << 16
            | lengthBytes[2] << 8
            | lengthBytes[3];
        if (bigEndian >= 0)
        {
            return bigEndian;
        }

        var flaggedBigEndian = bigEndian & 0x7fffffff;
        if (flaggedBigEndian > 0 && flaggedBigEndian <= 256 * 1024 * 1024)
        {
            return flaggedBigEndian;
        }

        var littleEndian =
            lengthBytes[0]
            | lengthBytes[1] << 8
            | lengthBytes[2] << 16
            | lengthBytes[3] << 24;
        if (littleEndian >= 0 && littleEndian <= 256 * 1024 * 1024)
        {
            return littleEndian;
        }

        return bigEndian;
    }

    private static int ReadAtMost(Stream input, Span<byte> buffer)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = input.Read(buffer[offset..]);
            if (read == 0)
            {
                break;
            }
            offset += read;
        }
        return offset;
    }
}

sealed class LimitedReadStream(Stream inner, int length) : Stream
{
    private int remaining = length;

    public int Remaining => remaining;
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    public override int Read(byte[] buffer, int offset, int count)
    {
        if (remaining == 0)
        {
            return 0;
        }
        var read = inner.Read(buffer, offset, Math.Min(count, remaining));
        remaining -= read;
        return read;
    }

    public override int Read(Span<byte> buffer)
    {
        if (remaining == 0)
        {
            return 0;
        }
        var read = inner.Read(buffer[..Math.Min(buffer.Length, remaining)]);
        remaining -= read;
        return read;
    }
}
