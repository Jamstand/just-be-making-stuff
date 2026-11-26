using System.IO;

namespace Recshot;

/// <summary>Tiny append-only log in %LOCALAPPDATA%\Recshot\logs. Handy when something goes wrong on a user's PC.</summary>
internal static class Log
{
    private static readonly object Gate = new();

    public static string Directory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Recshot", "logs");

    public static string FilePath { get; } = Path.Combine(Directory, "recshot.log");

    static Log()
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            var info = new FileInfo(FilePath);
            if (info.Exists && info.Length > 5 * 1024 * 1024)
                File.Move(FilePath, FilePath + ".old", overwrite: true);
        }
        catch
        {
            // Logging must never take the app down.
        }
    }

    public static void Info(string message) => Write("INFO", message);
    public static void Warn(string message) => Write("WARN", message);

    public static void Error(string message, Exception? ex = null)
        => Write("ERROR", ex == null ? message : $"{message}: {ex}");

    private static void Write(string level, string message)
    {
        string line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {message}{Environment.NewLine}";
        System.Diagnostics.Debug.Write(line);
        try
        {
            lock (Gate) File.AppendAllText(FilePath, line);
        }
        catch
        {
        }
    }
}
