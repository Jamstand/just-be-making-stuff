using System.Globalization;
using System.IO;

namespace Recshot.Encode;

/// <summary>Reads the segment list the replay buffer's FFmpeg keeps up to date, and picks segments to save.</summary>
internal static class ReplaySegments
{
    public readonly record struct Segment(string Path, double Start, double End);

    /// <summary>Parses FFmpeg's CSV segment list ("file,start,end" per line). Missing/half-written files give an empty list.</summary>
    public static List<Segment> Read(string listPath)
    {
        var result = new List<Segment>();
        string dir = System.IO.Path.GetDirectoryName(listPath) ?? "";
        try
        {
            using var stream = new FileStream(listPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            while (reader.ReadLine() is { } line)
            {
                string[] parts = line.Split(',');
                if (parts.Length < 3)
                    continue;
                if (!double.TryParse(parts[^2], NumberStyles.Float, CultureInfo.InvariantCulture, out double start) ||
                    !double.TryParse(parts[^1], NumberStyles.Float, CultureInfo.InvariantCulture, out double end))
                    continue;
                string file = string.Join(",", parts[..^2]).Trim().Trim('"');
                if (file.Length == 0)
                    continue;
                result.Add(new Segment(System.IO.Path.IsPathRooted(file) ? file : System.IO.Path.Combine(dir, file), start, end));
            }
        }
        catch (IOException)
        {
            // Not written yet, or being rewritten right now.
        }
        catch (UnauthorizedAccessException)
        {
        }
        return result;
    }

    /// <summary>The newest segments covering the last <paramref name="seconds"/> seconds.</summary>
    public static List<Segment> LastSeconds(IReadOnlyList<Segment> segments, int seconds)
    {
        if (segments.Count == 0)
            return [];
        double lastEnd = segments[^1].End;
        // Walk back from the newest; stop at a time jump (a wrapped/stale entry) to keep the clip continuous.
        var picked = new List<Segment>();
        for (int i = segments.Count - 1; i >= 0; i--)
        {
            Segment s = segments[i];
            if (s.End <= lastEnd - seconds + 0.05)
                break;
            if (picked.Count > 0 && Math.Abs(picked[^1].Start - s.End) > 0.5)
                break;
            picked.Add(s);
        }
        picked.Reverse();
        return picked;
    }
}
