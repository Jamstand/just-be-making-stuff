using System.Globalization;
using System.IO;
using Recshot.Core;

namespace Recshot.Encode;

internal enum SessionKind { Recording, Replay }

/// <summary>Builds the FFmpeg command line for a recording or replay-buffer session.</summary>
internal static class FfmpegArgs
{
    public sealed record AudioInput(string Path, int SampleRate, string Title);

    public sealed record VideoInput(string Path, VideoPixelFormat PixelFormat, int Width, int Height, int Fps);

    /// <param name="output">Recording: the .mkv path. Replay: the folder that receives the segments.</param>
    /// <param name="replayListPath">Replay only: CSV list FFmpeg keeps updated with the finished segments.</param>
    public static List<string> Build(SessionKind kind, VideoInput video, IReadOnlyList<AudioInput> audio,
        EncoderInfo encoder, QualityPreset quality, string output, string? replayListPath = null, int replaySeconds = 0)
    {
        var args = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "warning", "-y" };

        // Inputs: raw frames and raw float audio arrive through pipes, so nothing needs probing.
        args.AddRange([
            "-thread_queue_size", "16", "-probesize", "32", "-analyzeduration", "0",
            "-f", "rawvideo",
            "-pix_fmt", video.PixelFormat == VideoPixelFormat.Nv12 ? "nv12" : "bgra",
            "-video_size", $"{video.Width}x{video.Height}",
            "-framerate", video.Fps.ToString(CultureInfo.InvariantCulture),
            "-i", video.Path,
        ]);
        foreach (AudioInput a in audio)
        {
            args.AddRange([
                "-thread_queue_size", "1024", "-probesize", "32", "-analyzeduration", "0",
                "-f", "f32le", "-ar", a.SampleRate.ToString(CultureInfo.InvariantCulture), "-ch_layout", "stereo",
                "-i", a.Path,
            ]);
        }

        // Audio graph. Two sources → track 1 = both mixed (what players play), 2 and 3 = each on its own.
        var maps = new List<string> { "-map", "0:v" };
        List<string> titles = AudioTitles(audio);
        if (audio.Count == 1)
        {
            args.AddRange(["-filter_complex", "[1:a]aresample=48000[a0]"]);
            maps.AddRange(["-map", "[a0]"]);
        }
        else if (audio.Count == 2)
        {
            args.AddRange(["-filter_complex",
                "[1:a]aresample=48000,asplit=2[s0][s1];" +
                "[2:a]aresample=48000,asplit=2[m0][m1];" +
                "[s0][m0]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[mix]"]);
            maps.AddRange(["-map", "[mix]", "-map", "[s1]", "-map", "[m1]"]);
        }
        args.AddRange(maps);

        if (video.PixelFormat == VideoPixelFormat.Bgra)
            args.AddRange(["-vf", "scale=out_color_matrix=bt709:out_range=tv,format=nv12"]);

        // Recordings: a keyframe at least every 2 s (good seeking in editors).
        // Replay: a keyframe on every whole second, so each segment is exactly 1 s and saved clips are exactly as long as asked.
        int gop = kind == SessionKind.Replay ? video.Fps : video.Fps * 2;
        args.AddRange(EncoderCatalog.VideoArgs(encoder, quality, gop));
        if (kind == SessionKind.Replay)
        {
            args.AddRange(["-force_key_frames", "expr:gte(t,n_forced*1)"]);
            if (encoder.Vendor == "nvidia")
                args.AddRange(["-forced-idr", "1"]); // forced frames must be IDR to count as cut points
        }

        if (titles.Count > 0)
        {
            args.AddRange(["-c:a", "aac", "-b:a", "192k", "-ar", "48000"]);
            for (int i = 0; i < titles.Count; i++)
            {
                args.AddRange([$"-metadata:s:a:{i}", $"title={titles[i]}"]);
                args.AddRange([$"-disposition:a:{i}", i == 0 ? "default" : "0"]);
            }
        }

        if (kind == SessionKind.Recording)
        {
            // Matroska survives crashes and power cuts; it's rewrapped to MP4 after a clean stop.
            args.AddRange(["-f", "matroska", output]);
        }
        else
        {
            if (replayListPath == null || replaySeconds <= 0)
                throw new ArgumentException("Replay sessions need a list path and a length.");
            args.AddRange([
                "-f", "segment", "-segment_time", "1", "-segment_format", "mpegts",
                // Segment files are reused in a ring, so the buffer never grows on disk.
                "-segment_wrap", (replaySeconds + 20).ToString(CultureInfo.InvariantCulture),
                "-segment_list", replayListPath, "-segment_list_type", "csv",
                "-segment_list_size", (replaySeconds + 10).ToString(CultureInfo.InvariantCulture),
                "-reset_timestamps", "0",
                Path.Combine(output, "seg%03d.ts"),
            ]);
        }
        return args;
    }

    /// <summary>Names of the output audio tracks, in order. Two sources → mix first, then each on its own.</summary>
    public static List<string> AudioTitles(IReadOnlyList<AudioInput> audio) => audio.Count switch
    {
        0 => [],
        1 => [audio[0].Title],
        2 => [$"Mixed ({audio[0].Title.ToLowerInvariant()} + {audio[1].Title.ToLowerInvariant()})", audio[0].Title, audio[1].Title],
        _ => throw new ArgumentException("At most two audio sources are supported.", nameof(audio)),
    };

    /// <summary>Lossless rewrap of a finished MKV into an MP4 that every player and editor opens.</summary>
    public static List<string> RemuxToMp4(string input, string output, IReadOnlyList<string> audioTitles, string codec)
        => ToMp4(["-i", input], output, audioTitles, codec, fromTransportStream: false);

    /// <summary>
    /// Joins replay segments into one MP4 without re-encoding. The segments are MPEG-TS cut from one
    /// continuous stream with untouched timestamps, so byte-level concatenation (the concat: protocol)
    /// gives back exactly that stream. Run with the segment folder as the working directory.
    /// </summary>
    public static List<string> ConcatToMp4(IReadOnlyList<string> segmentFileNames, string output, IReadOnlyList<string> audioTitles, string codec)
        => ToMp4(["-f", "mpegts", "-i", "concat:" + string.Join("|", segmentFileNames)], output, audioTitles, codec, fromTransportStream: true);

    private static List<string> ToMp4(string[] input, string output, IReadOnlyList<string> audioTitles, string codec, bool fromTransportStream)
    {
        var args = new List<string> { "-hide_banner", "-nostdin", "-loglevel", "error", "-y" };
        args.AddRange(input);
        args.AddRange(["-map", "0", "-c", "copy", "-movflags", "+faststart"]);
        if (fromTransportStream && audioTitles.Count > 0)
            args.AddRange(["-bsf:a", "aac_adtstoasc"]);
        if (codec == "hevc")
            args.AddRange(["-tag:v", "hvc1"]);
        // MP4 keeps track names in handler_name (Matroska's "title" doesn't carry over).
        args.AddRange(["-metadata:s:v:0", "handler_name=Screen"]);
        for (int i = 0; i < audioTitles.Count; i++)
            args.AddRange([$"-metadata:s:a:{i}", $"handler_name={audioTitles[i]}", $"-disposition:a:{i}", i == 0 ? "default" : "0"]);
        args.Add(output);
        return args;
    }

    public static string ForLog(IEnumerable<string> args)
        => "ffmpeg " + string.Join(" ", args.Select(a => a.Contains(' ') || a.Contains(';') ? $"\"{a}\"" : a));
}
