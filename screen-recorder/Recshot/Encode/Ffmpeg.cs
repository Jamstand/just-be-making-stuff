using System.Diagnostics;
using System.IO;
using System.Text;

namespace Recshot.Encode;

/// <summary>Finding and running ffmpeg.exe.</summary>
internal static class Ffmpeg
{
    public static string? Locate()
    {
        string baseDir = AppContext.BaseDirectory;
        string[] local =
        [
            Path.Combine(baseDir, "ffmpeg.exe"),
            Path.Combine(baseDir, "ffmpeg", "ffmpeg.exe"),
            Path.Combine(baseDir, "ffmpeg", "bin", "ffmpeg.exe"),
        ];
        foreach (string candidate in local)
        {
            if (File.Exists(candidate))
                return candidate;
        }

        foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string candidate = Path.Combine(dir.Trim('"'), "ffmpeg.exe");
                if (File.Exists(candidate))
                    return candidate;
            }
            catch
            {
                // Malformed PATH entry.
            }
        }
        return null;
    }

    public static ProcessStartInfo StartInfo(string ffmpeg, IEnumerable<string> args)
    {
        var psi = new ProcessStartInfo(ffmpeg)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            StandardErrorEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (string a in args)
            psi.ArgumentList.Add(a);
        return psi;
    }

    /// <summary>Runs ffmpeg to completion. Returns the exit code (-1 on timeout) and stderr.</summary>
    public static async Task<(int ExitCode, string Output)> RunAsync(string ffmpeg, IEnumerable<string> args, TimeSpan timeout,
        string? workingDirectory = null)
    {
        using var process = new Process { StartInfo = StartInfo(ffmpeg, args) };
        if (workingDirectory != null)
            process.StartInfo.WorkingDirectory = workingDirectory;
        var output = new StringBuilder();
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data != null)
                lock (output) output.AppendLine(e.Data);
        };
        process.OutputDataReceived += (_, _) => { };
        process.Start();
        process.BeginErrorReadLine();
        process.BeginOutputReadLine();

        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch
            {
            }
            return (-1, "timed out");
        }
        lock (output)
            return (process.ExitCode, output.ToString());
    }

    /// <summary>Lossless rewrap of a finished MKV into an MP4 that every player and editor understands.</summary>
    public static async Task RemuxToMp4Async(string ffmpeg, string input, string output, IReadOnlyList<string> audioTitles, string codec)
    {
        var (code, log) = await RunAsync(ffmpeg, FfmpegArgs.RemuxToMp4(input, output, audioTitles, codec), TimeSpan.FromMinutes(30));
        if (code != 0 || !File.Exists(output) || new FileInfo(output).Length == 0)
        {
            TryDelete(output);
            throw new IOException($"Couldn't convert to MP4: {LastLines(log, 3)}");
        }
    }

    public static string LastLines(string text, int count)
    {
        string[] lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return string.Join(" | ", lines.TakeLast(count));
    }

    public static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
        }
    }
}
