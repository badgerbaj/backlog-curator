using System.Buffers;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using ValveKeyValue;

// Appinfo file layout handling follows the MIT-licensed SteamDB SteamAppInfo parser.
// See THIRD_PARTY_NOTICES.md for attribution.
namespace SteamMetadataReader;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            return Run(args);
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or InvalidDataException)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static int Run(string[] args)
    {
        var options = CliOptions.Parse(args);
        if (options.ShowHelp)
        {
            CliOptions.WriteUsage();
            return 0;
        }

        if (string.IsNullOrWhiteSpace(options.AppInfoPath))
        {
            Console.Error.WriteLine("Missing required --appinfo path.");
            CliOptions.WriteUsage();
            return 2;
        }

        if (string.IsNullOrWhiteSpace(options.OutputPath))
        {
            Console.Error.WriteLine("Missing required --output path.");
            CliOptions.WriteUsage();
            return 2;
        }

        var appInfo = new AppInfoFile();
        appInfo.Read(options.AppInfoPath);

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(options.OutputPath))!);

        using var writer = new StreamWriter(options.OutputPath, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        writer.WriteLine("AppId,Title,Type,Developer,Publisher,Franchise,LastUpdated,ChangeNumber");

        var rows = 0;
        foreach (var app in appInfo.Apps.OrderBy(app => app.AppId))
        {
            var row = AppMetadata.FromApp(app);
            if (options.GamesOnly && !string.Equals(row.Type, "Game", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (string.IsNullOrWhiteSpace(row.Title))
            {
                continue;
            }

            writer.WriteLine(string.Join(",", new[]
            {
                Csv(row.AppId.ToString(CultureInfo.InvariantCulture)),
                Csv(row.Title),
                Csv(row.Type),
                Csv(row.Developer),
                Csv(row.Publisher),
                Csv(row.Franchise),
                Csv(row.LastUpdated.ToString("O", CultureInfo.InvariantCulture)),
                Csv(row.ChangeNumber.ToString(CultureInfo.InvariantCulture)),
            }));
            rows++;
        }

        Console.WriteLine($"Read apps: {appInfo.Apps.Count}");
        Console.WriteLine($"Wrote rows: {rows}");
        Console.WriteLine($"Output: {Path.GetFullPath(options.OutputPath)}");
        return 0;
    }

    private static string Csv(string? value)
    {
        value ??= string.Empty;
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }
}

internal sealed record CliOptions(string? AppInfoPath, string? OutputPath, bool GamesOnly, bool ShowHelp)
{
    public static CliOptions Parse(string[] args)
    {
        string? appInfoPath = null;
        string? outputPath = null;
        var gamesOnly = true;
        var showHelp = false;

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "-h":
                case "--help":
                    showHelp = true;
                    break;
                case "--appinfo":
                    appInfoPath = RequireValue(args, ref i, arg);
                    break;
                case "--output":
                    outputPath = RequireValue(args, ref i, arg);
                    break;
                case "--all-app-types":
                    gamesOnly = false;
                    break;
                default:
                    throw new ArgumentException($"Unknown argument: {arg}");
            }
        }

        return new CliOptions(appInfoPath, outputPath, gamesOnly, showHelp);
    }

    public static void WriteUsage()
    {
        Console.WriteLine("Usage:");
        Console.WriteLine("  SteamMetadataReader --appinfo <path> --output <csv> [--all-app-types]");
    }

    private static string RequireValue(string[] args, ref int index, string name)
    {
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException($"Missing value for {name}.");
        }

        index++;
        return args[index];
    }
}

internal sealed record AppMetadata(
    uint AppId,
    string Title,
    string Type,
    string Developer,
    string Publisher,
    string Franchise,
    DateTime LastUpdated,
    uint ChangeNumber)
{
    public static AppMetadata FromApp(AppInfoEntry app)
    {
        var root = app.Data.Root;
        var common = TryGet(root, "common");
        var extended = TryGet(root, "extended");

        return new AppMetadata(
            app.AppId,
            GetString(common, "name"),
            GetString(common, "type"),
            FirstNonEmpty(GetString(extended, "developer"), GetString(common, "developer")),
            FirstNonEmpty(GetString(extended, "publisher"), GetString(common, "publisher")),
            FirstNonEmpty(GetString(extended, "franchise"), GetString(common, "franchise")),
            app.LastUpdated,
            app.ChangeNumber);
    }

    private static KVObject? TryGet(KVObject? parent, string key)
    {
        if (parent is null)
        {
            return null;
        }

        return parent.TryGetValue(key, out var child) ? child : null;
    }

    private static string GetString(KVObject? parent, string key)
    {
        if (parent is null || !parent.TryGetValue(key, out var value))
        {
            return string.Empty;
        }

        try
        {
            return ((string)value).Trim();
        }
        catch (InvalidCastException)
        {
            return value.ToString()?.Trim() ?? string.Empty;
        }
    }

    private static string FirstNonEmpty(params string[] values)
    {
        return values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? string.Empty;
    }
}

internal sealed class AppInfoEntry
{
    public uint AppId { get; init; }
    public uint InfoState { get; init; }
    public DateTime LastUpdated { get; init; }
    public ulong Token { get; init; }
    public ReadOnlyCollection<byte> Hash { get; init; } = new([]);
    public ReadOnlyCollection<byte> BinaryDataHash { get; init; } = new([]);
    public uint ChangeNumber { get; init; }
    public required KVDocument Data { get; init; }
}

internal sealed class AppInfoFile
{
    public List<AppInfoEntry> Apps { get; } = [];

    public void Read(string filename)
    {
        using var fs = new FileStream(filename, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        Read(fs);
    }

    private void Read(Stream input)
    {
        using var reader = new BinaryReader(input, Encoding.UTF8, leaveOpen: true);
        var magic = reader.ReadUInt32();
        var version = magic & 0xFF;
        magic >>= 8;

        if (magic != 0x07_56_44)
        {
            throw new InvalidDataException($"Unknown appinfo magic header: 0x{magic:X}");
        }

        if (version is < 39 or > 41)
        {
            throw new InvalidDataException($"Unsupported appinfo version: {version}");
        }

        _ = reader.ReadUInt32(); // Universe. Steam public universe is 1.

        var serializerOptions = new KVSerializerOptions();
        if (version >= 41)
        {
            serializerOptions.StringTable = ReadStringTable(reader);
        }

        var deserializer = KVSerializer.Create(KVSerializationFormat.KeyValues1Binary);

        while (true)
        {
            var appId = reader.ReadUInt32();
            if (appId == 0)
            {
                break;
            }

            var size = reader.ReadUInt32();
            var end = reader.BaseStream.Position + size;

            var app = new AppInfoEntry
            {
                AppId = appId,
                InfoState = reader.ReadUInt32(),
                LastUpdated = DateTimeOffset.FromUnixTimeSeconds(reader.ReadUInt32()).UtcDateTime,
                Token = reader.ReadUInt64(),
                Hash = new ReadOnlyCollection<byte>(reader.ReadBytes(20)),
                ChangeNumber = reader.ReadUInt32(),
                BinaryDataHash = version >= 40 ? new ReadOnlyCollection<byte>(reader.ReadBytes(20)) : new ReadOnlyCollection<byte>([]),
                Data = deserializer.Deserialize(input, serializerOptions),
            };

            if (reader.BaseStream.Position != end)
            {
                throw new InvalidDataException($"App {appId} ended at {reader.BaseStream.Position}, expected {end}.");
            }

            Apps.Add(app);
        }
    }

    private static StringTable ReadStringTable(BinaryReader reader)
    {
        var stringTableOffset = reader.ReadInt64();
        var originalOffset = reader.BaseStream.Position;
        reader.BaseStream.Position = stringTableOffset;

        var stringCount = reader.ReadUInt32();
        var stringPool = new string[stringCount];
        for (var i = 0; i < stringCount; i++)
        {
            stringPool[i] = ReadNullTerminatedUtf8String(reader.BaseStream);
        }

        reader.BaseStream.Position = originalOffset;
        return new StringTable(stringPool);
    }

    private static string ReadNullTerminatedUtf8String(Stream stream)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(64);
        try
        {
            var position = 0;
            while (true)
            {
                var b = stream.ReadByte();
                if (b <= 0)
                {
                    break;
                }

                if (position >= buffer.Length)
                {
                    var larger = ArrayPool<byte>.Shared.Rent(buffer.Length * 2);
                    Buffer.BlockCopy(buffer, 0, larger, 0, buffer.Length);
                    ArrayPool<byte>.Shared.Return(buffer);
                    buffer = larger;
                }

                buffer[position++] = (byte)b;
            }

            return Encoding.UTF8.GetString(buffer.AsSpan(0, position));
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
