using Recshot.Core;

namespace Recshot.Encode;

/// <summary>The video encoders Recshot knows how to drive, and their quality settings.</summary>
internal static class EncoderCatalog
{
    public static readonly EncoderInfo[] All =
    [
        new("h264_nvenc", "NVIDIA NVENC · H.264 (most compatible)", "nvidia", "h264"),
        new("hevc_nvenc", "NVIDIA NVENC · HEVC / H.265 (smaller files)", "nvidia", "hevc"),
        new("av1_nvenc", "NVIDIA NVENC · AV1 (RTX 40/50, smallest files)", "nvidia", "av1"),
        new("h264_amf", "AMD AMF · H.264", "amd", "h264"),
        new("hevc_amf", "AMD AMF · HEVC / H.265", "amd", "hevc"),
        new("h264_qsv", "Intel Quick Sync · H.264", "intel", "h264"),
        new("hevc_qsv", "Intel Quick Sync · HEVC / H.265", "intel", "hevc"),
        new("libx264", "CPU · x264 H.264 (no GPU needed, heavier)", "cpu", "h264"),
    ];

    public static EncoderInfo Software => All[^1];

    /// <summary>
    /// Tries a tiny encode with each encoder. Being listed by FFmpeg isn't enough: NVENC/AMF/QSV only
    /// work if the matching GPU and driver are actually present.
    /// </summary>
    public static async Task<List<EncoderInfo>> ProbeAsync(string ffmpeg)
    {
        var tasks = All.Select(async enc =>
        {
            string[] args =
            [
                "-hide_banner", "-nostdin", "-loglevel", "error",
                "-f", "lavfi", "-i", "color=c=black:s=1280x720:r=30",
                "-frames:v", "5", "-pix_fmt", "nv12",
                "-c:v", enc.Id,
                "-f", "null", "-",
            ];
            try
            {
                var (code, output) = await Ffmpeg.RunAsync(ffmpeg, args, TimeSpan.FromSeconds(20));
                if (code != 0)
                    Log.Info($"Encoder {enc.Id} unavailable: {Ffmpeg.LastLines(output, 2)}");
                return code == 0 ? enc : null;
            }
            catch (Exception ex)
            {
                Log.Warn($"Encoder probe {enc.Id} failed: {ex.Message}");
                return null;
            }
        }).ToList();

        EncoderInfo?[] results = await Task.WhenAll(tasks);
        var available = results.Where(e => e != null).Cast<EncoderInfo>().ToList();
        Log.Info("Encoders available: " + string.Join(", ", available.Select(e => e.Id)));
        return available;
    }

    /// <summary>Picks the best default: NVIDIA, then AMD, then Intel hardware H.264, else CPU.</summary>
    public static EncoderInfo PickDefault(IReadOnlyList<EncoderInfo> available)
        => available.FirstOrDefault(e => e.Id == "h264_nvenc")
           ?? available.FirstOrDefault(e => e.Id == "h264_amf")
           ?? available.FirstOrDefault(e => e.Id == "h264_qsv")
           ?? available.FirstOrDefault()
           ?? Software;

    /// <summary>FFmpeg output arguments for the video stream (input is NV12, BT.709 limited range).</summary>
    public static List<string> VideoArgs(EncoderInfo enc, QualityPreset quality, int gopFrames)
    {
        int step = quality switch
        {
            QualityPreset.Ultra => 0,
            QualityPreset.High => 1,
            QualityPreset.Medium => 2,
            _ => 3,
        };
        var a = new List<string> { "-c:v", enc.Id };

        switch (enc.Vendor)
        {
            case "nvidia":
                // Constant-quality VBR: bitrate follows the content instead of a fixed target.
                int cq = enc.Codec == "av1" ? new[] { 24, 30, 36, 42 }[step] : new[] { 16, 20, 24, 28 }[step];
                a.AddRange(["-preset", "p5", "-tune", "hq", "-rc", "vbr", "-cq", cq.ToString(), "-b:v", "0", "-spatial-aq", "1"]);
                if (enc.Codec == "h264")
                    a.AddRange(["-profile:v", "high"]);
                else if (enc.Codec == "hevc")
                    a.AddRange(["-profile:v", "main"]);
                break;

            case "amd":
                int qp = new[] { 18, 22, 26, 30 }[step];
                a.AddRange(["-quality", "quality", "-rc", "cqp", "-qp_i", qp.ToString(), "-qp_p", (qp + 2).ToString()]);
                if (enc.Codec == "h264")
                    a.AddRange(["-qp_b", (qp + 4).ToString(), "-profile:v", "high"]);
                break;

            case "intel":
                int icq = new[] { 18, 22, 26, 30 }[step];
                a.AddRange(["-preset", "medium", "-global_quality", icq.ToString()]);
                break;

            default:
                int crf = new[] { 16, 19, 23, 27 }[step];
                a.AddRange(["-preset", "veryfast", "-crf", crf.ToString(), "-profile:v", "high"]);
                break;
        }

        a.AddRange(["-g", gopFrames.ToString()]);
        a.AddRange(["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv"]);
        return a;
    }
}
