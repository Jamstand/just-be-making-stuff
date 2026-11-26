// Cross-platform checks for Recshot's encoding side: the exact FFmpeg command lines Recshot builds are
// run end-to-end through FIFOs (CPU x264 instead of NVENC), and the outputs are inspected with ffprobe.
// Exit code 0 = all passed.

using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Recshot.Core;
using Recshot.Encode;

CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
int failures = 0;

void Check(bool ok, string name, string detail = "")
{
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {name}{(detail.Length > 0 ? $"  ({detail})" : "")}");
    if (!ok)
        failures++;
}

TestAudioTimeline();
TestReplaySegments();

if (OperatingSystem.IsWindows() || !CommandExists("ffmpeg") || !CommandExists("ffprobe"))
{
    Console.WriteLine("SKIP  FFmpeg end-to-end tests (need Linux/macOS with ffmpeg + ffprobe on PATH)");
}
else
{
    await TestRecordingTwoTracksAsync();
    await TestRecordingBgraOneTrackAsync();
    await TestReplayBufferAsync();
}

Console.WriteLine(failures == 0 ? "\nAll checks passed." : $"\n{failures} check(s) failed.");
return failures == 0 ? 0 : 1;

// =====================================================================
// AudioTimeline
// =====================================================================

void TestAudioTimeline()
{
    const int rate = 48000, packet = 480; // 10 ms packets
    var rng = new Random(1);

    // Steady device with arrival jitter: nothing should be padded or trimmed.
    var tl = new AudioTimeline(rate);
    var sink = new CountingStream();
    for (int i = 0; i < 1000; i++)
        tl.Write(new float[packet * 2], packet, i * packet + rng.Next(-200, 200), sink);
    Check(tl.Written == 1000 * packet && tl.InsertedSilence == 0 && tl.DroppedFrames == 0,
        "timeline: jitter is ignored", $"written {tl.Written}, pad {tl.InsertedSilence}, trim {tl.DroppedFrames}");
    Check(sink.Bytes == tl.Written * 8, "timeline: bytes written match frames");

    // Device goes quiet for exactly 1 s (WASAPI loopback while nothing plays): 1 s of silence goes in.
    tl = new AudioTimeline(rate);
    sink = new CountingStream();
    for (int i = 0; i < 100; i++)
        tl.Write(new float[packet * 2], packet, i * packet, sink);
    for (int i = 100; i < 200; i++)
        tl.Write(new float[packet * 2], packet, i * packet + rate, sink);
    Check(tl.InsertedSilence == rate && tl.Written == 200 * packet + rate, "timeline: a silent gap becomes silence",
        $"pad {tl.InsertedSilence}");

    // Device clock 0.2% fast / slow over ~100 s: stays within tolerance of the wall clock.
    foreach (int framesPerPacket in new[] { 481, 479 })
    {
        tl = new AudioTimeline(rate);
        sink = new CountingStream();
        const int packets = 10_000;
        for (int i = 0; i < packets; i++)
            tl.Write(new float[framesPerPacket * 2], framesPerPacket, (long)i * packet, sink);
        long wallClockEnd = (long)packets * packet;
        long error = Math.Abs(tl.Written - wallClockEnd);
        Check(error <= rate * 0.045, $"timeline: {(framesPerPacket > packet ? "fast" : "slow")} device clock stays in sync",
            $"off by {error * 1000.0 / rate:F1} ms after 100 s, pad {tl.InsertedSilence}, trim {tl.DroppedFrames}");
    }

    // Silence padded in real time, then a packet arrives late overlapping it: the overlap is dropped.
    tl = new AudioTimeline(rate);
    sink = new CountingStream();
    tl.PadTo(rate, sink);
    tl.Write(new float[packet * 20 * 2], packet * 20, rate - 4800, sink);
    Check(tl.DroppedFrames == 4800 && tl.Written == rate + packet * 20 - 4800, "timeline: late overlap is trimmed",
        $"trim {tl.DroppedFrames}");

    // PadTo never goes backwards.
    long before = tl.Written;
    tl.PadTo(10, sink);
    Check(tl.Written == before, "timeline: PadTo is a no-op behind the write position");
}

// =====================================================================
// Replay segment list
// =====================================================================

void TestReplaySegments()
{
    string dir = Directory.CreateTempSubdirectory("recshot-seg").FullName;
    string list = Path.Combine(dir, "segments.csv");
    var lines = new List<string> { "seg098.ts,-1.000000,0.000000" }; // stale entry from before a discontinuity
    for (int i = 0; i < 10; i++)
        lines.Add($"seg{i:000}.ts,{i + 5}.000000,{i + 6}.016667");
    File.WriteAllLines(list, lines);

    var segments = ReplaySegments.Read(list);
    Check(segments.Count == 11 && segments[1].Path == Path.Combine(dir, "seg000.ts"), "segments: CSV parsed, paths resolved");

    var last3 = ReplaySegments.LastSeconds(segments, 3);
    Check(last3.Count == 3 && last3[0].Path.EndsWith("seg007.ts") && last3[^1].Path.EndsWith("seg009.ts"),
        "segments: picks the newest 3 s", string.Join(",", last3.Select(s => Path.GetFileName(s.Path))));

    var all = ReplaySegments.LastSeconds(segments, 300);
    Check(all.Count == 10, "segments: stops at a timestamp jump", $"{all.Count} picked");

    Check(ReplaySegments.Read(Path.Combine(dir, "missing.csv")).Count == 0, "segments: missing list → empty");

    var join = FfmpegArgs.ConcatToMp4(["seg007.ts", "seg008.ts"], "out.mp4", ["Mixed", "A", "B"], "hevc");
    Check(join.Contains("concat:seg007.ts|seg008.ts") && join.Contains("hvc1") && join.Contains("handler_name=B"),
        "segments: join command uses the concat protocol");
    Directory.Delete(dir, true);
}

// =====================================================================
// FFmpeg end-to-end
// =====================================================================

async Task TestRecordingTwoTracksAsync()
{
    const int w = 640, h = 360, fps = 30;
    const double seconds = 5;
    string dir = Directory.CreateTempSubdirectory("recshot-rec").FullName;
    string mkv = Path.Combine(dir, "test.mkv");

    // System audio: silent 0.5–1.5 s (no packets at all, like loopback), beep at 2.0 s. Mic at 44.1 kHz, beep at 3.0 s.
    var system = new SyntheticAudio("System audio", 48000, BeepAt: 2.0, GapFrom: 0.5, GapTo: 1.5);
    var mic = new SyntheticAudio("Microphone", 44100, BeepAt: 3.0, GapFrom: -1, GapTo: -1);
    bool ok = await RunSessionAsync(SessionKind.Recording, VideoPixelFormat.Nv12, w, h, fps, seconds, flashAt: 2.0,
        [system, mic], mkv, dir, null, 0);
    Check(ok && File.Exists(mkv), "record: ffmpeg encodes NV12 + 2 audio pipes to MKV");
    if (!ok)
        return;

    string mp4 = Path.ChangeExtension(mkv, ".mp4");
    await Ffmpeg.RemuxToMp4Async("ffmpeg", mkv, mp4, ["Mixed (system audio + microphone)", "System audio", "Microphone"], "h264");
    var probe = await ProbeAsync(mp4);
    var streams = probe.GetProperty("streams").EnumerateArray().ToList();
    var audio = streams.Where(s => s.GetProperty("codec_type").GetString() == "audio").ToList();
    Check(streams.Count(s => s.GetProperty("codec_type").GetString() == "video") == 1 && audio.Count == 3,
        "record: MP4 has 1 video + 3 audio tracks", $"{streams.Count} streams");

    string[] titles = audio.Select(a => a.TryGetProperty("tags", out var t) && t.TryGetProperty("handler_name", out var v) ? v.GetString() ?? "" : "").ToArray();
    Check(titles.SequenceEqual(["Mixed (system audio + microphone)", "System audio", "Microphone"]),
        "record: track titles", string.Join(" | ", titles));
    Check(audio[0].GetProperty("disposition").GetProperty("default").GetInt32() == 1 &&
          audio[1].GetProperty("disposition").GetProperty("default").GetInt32() == 0,
        "record: mixed track is the default");
    Check(audio.All(a => a.GetProperty("sample_rate").GetString() == "48000"), "record: all tracks resampled to 48 kHz");

    double duration = double.Parse(probe.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
    Check(Math.Abs(duration - seconds) < 0.15, "record: duration", $"{duration:F3} s");

    var video = streams.First(s => s.GetProperty("codec_type").GetString() == "video");
    Check(video.GetProperty("color_space").GetString() == "bt709" && video.GetProperty("color_range").GetString() == "tv",
        "record: BT.709 limited-range tags");

    // A/V sync: the white flash frame and the system beep were both placed at 2.0 s; mic beep at 3.0 s.
    // (Everything in the MP4 sits ~21 ms later because of AAC encoder priming; only relative timing matters.)
    double flash = await FirstBrightFrameAsync(mp4);
    double sysBeep = await FirstLoudSampleAsync(mp4, 1);
    double micBeep = await FirstLoudSampleAsync(mp4, 2);
    double mixFirst = await FirstLoudSampleAsync(mp4, 0);
    Check(Math.Abs(flash - 2.0) < 0.03, "record: flash frame lands at 2.0 s", $"{flash:F3} s");
    Check(Math.Abs(sysBeep - 2.0) < 0.03, "record: system beep lands at 2.0 s (after a 1 s device gap)", $"{sysBeep:F3} s");
    Check(Math.Abs(micBeep - sysBeep - 1.0) < 0.005, "record: 44.1 kHz mic beep lands 1.0 s after it", $"{micBeep:F3} s");
    Check(Math.Abs(mixFirst - sysBeep) < 0.005, "record: mixed track carries the beeps", $"{mixFirst:F3} s");
    Check(Math.Abs(flash - sysBeep) < 0.5 / fps, "record: audio/video in sync", $"Δ {(sysBeep - flash) * 1000:F0} ms");
    Directory.Delete(dir, true);
}

async Task TestRecordingBgraOneTrackAsync()
{
    string dir = Directory.CreateTempSubdirectory("recshot-bgra").FullName;
    string mkv = Path.Combine(dir, "bgra.mkv");
    var mic = new SyntheticAudio("Microphone", 48000, BeepAt: 1.0, GapFrom: -1, GapTo: -1);
    bool ok = await RunSessionAsync(SessionKind.Recording, VideoPixelFormat.Bgra, 320, 240, 60, 2, flashAt: 1.0, [mic], mkv, dir, null, 0);
    Check(ok, "record (CPU colour fallback): BGRA input + 1 audio track");
    if (ok)
    {
        var probe = await ProbeAsync(mkv);
        var streams = probe.GetProperty("streams").EnumerateArray().ToList();
        Check(streams.Count == 2 && streams[0].GetProperty("pix_fmt").GetString() == "yuv420p",
            "record (CPU colour fallback): converted to 4:2:0", streams[0].GetProperty("pix_fmt").GetString() ?? "");
    }
    Directory.Delete(dir, true);
}

async Task TestReplayBufferAsync()
{
    const int fps = 30, replaySeconds = 3;
    string dir = Directory.CreateTempSubdirectory("recshot-replay").FullName;
    string segDir = Path.Combine(dir, "segments");
    Directory.CreateDirectory(segDir);
    string list = Path.Combine(segDir, "segments.csv");
    var system = new SyntheticAudio("System audio", 48000, BeepAt: 7.0, GapFrom: 2, GapTo: 3);
    var mic = new SyntheticAudio("Microphone", 48000, BeepAt: 7.5, GapFrom: -1, GapTo: -1);

    bool ok = await RunSessionAsync(SessionKind.Replay, VideoPixelFormat.Nv12, 640, 360, fps, 8, flashAt: 7.0,
        [system, mic], segDir, dir, list, replaySeconds);
    Check(ok, "replay: segment muxer runs");
    if (!ok)
        return;

    var segments = ReplaySegments.Read(list);
    Check(segments.Count >= replaySeconds && segments[^1].End > 7.5, "replay: segment list is written",
        $"{segments.Count} segments, last ends {segments.LastOrDefault().End:F2}");
    Check(Directory.GetFiles(segDir, "*.ts").Length <= replaySeconds + 20, "replay: segment files are recycled");

    var chosen = ReplaySegments.LastSeconds(segments, replaySeconds);
    if (Environment.GetEnvironmentVariable("RECSHOT_DEBUG") == "1")
    {
        Console.WriteLine("      list: " + string.Join("  ", segments.Select(x => $"{Path.GetFileName(x.Path)}[{x.Start:F3}-{x.End:F3}]")));
        Console.WriteLine("      chosen: " + string.Join("  ", chosen.Select(x => Path.GetFileName(x.Path))));
        foreach (var c in chosen)
        {
            var pr = await ProbeAsync(c.Path);
            Console.WriteLine($"      {Path.GetFileName(c.Path)}: " + string.Join("  ", pr.GetProperty("streams").EnumerateArray().Select(st =>
                $"{st.GetProperty("codec_type").GetString()} start {(st.TryGetProperty("start_time", out var v) ? v.GetString() : "?")} dur {(st.TryGetProperty("duration", out var d) ? d.GetString() : "?")}")));
        }
    }
    string mp4 = Path.Combine(dir, "replay.mp4");
    var names = chosen.Select(c => Path.GetFileName(c.Path)).ToList();
    var (code, output) = await Ffmpeg.RunAsync("ffmpeg",
        FfmpegArgs.ConcatToMp4(names, mp4, ["Mixed (system audio + microphone)", "System audio", "Microphone"], "h264"),
        TimeSpan.FromMinutes(1), segDir);
    Check(code == 0 && File.Exists(mp4), "replay: segments join into an MP4", Ffmpeg.LastLines(output, 2));
    if (code != 0)
        return;

    var probe = await ProbeAsync(mp4);
    double duration = double.Parse(probe.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
    int streamCount = probe.GetProperty("streams").GetArrayLength();
    if (Environment.GetEnvironmentVariable("RECSHOT_DEBUG") == "1")
        Console.WriteLine("      result: " + string.Join("  ", probe.GetProperty("streams").EnumerateArray().Select(st =>
            $"{st.GetProperty("codec_type").GetString()} start {st.GetProperty("start_time").GetString()} dur {st.GetProperty("duration").GetString()}")));
    Check(Math.Abs(duration - replaySeconds) < 0.15 && streamCount == 4,
        "replay: saved clip is the last ~3 s with all tracks", $"{duration:F2} s, {streamCount} streams");

    // The flash and the beep were both at 7.0 s in the session, i.e. ~2 s into the 3 s clip.
    double flash = await FirstBrightFrameAsync(mp4);
    double beep = await FirstLoudSampleAsync(mp4, 1);
    Check(flash >= 0 && Math.Abs(flash - beep) < 0.5 / fps, "replay: audio/video in sync in the saved clip",
        $"flash {flash:F3} s, beep {beep:F3} s");
    Check(Math.Abs(flash - (7.0 - (segments[^1].End - duration))) < 0.1, "replay: clip ends where the buffer ends",
        $"flash at {flash:F2} s of {duration:F2} s");
    Directory.Delete(dir, true);
}

/// <summary>Feeds a session exactly the way EncodeSession does on Windows, but through FIFOs.</summary>
async Task<bool> RunSessionAsync(SessionKind kind, VideoPixelFormat pf, int w, int h, int fps, double seconds, double flashAt,
    SyntheticAudio[] audio, string output, string workDir, string? listPath, int replaySeconds)
{
    string videoFifo = Path.Combine(workDir, "v.fifo");
    MakeFifo(videoFifo);
    var audioFifos = audio.Select((_, i) => Path.Combine(workDir, $"a{i}.fifo")).ToArray();
    foreach (string f in audioFifos)
        MakeFifo(f);

    List<string> args = FfmpegArgs.Build(kind,
        new FfmpegArgs.VideoInput(videoFifo, pf, w, h, fps),
        audio.Select((a, i) => new FfmpegArgs.AudioInput(audioFifos[i], a.Rate, a.Title)).ToList(),
        EncoderCatalog.Software, QualityPreset.Medium, output, listPath, replaySeconds);

    using var ffmpeg = new Process { StartInfo = Ffmpeg.StartInfo("ffmpeg", args) };
    var log = new System.Text.StringBuilder();
    ffmpeg.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (log) log.AppendLine(e.Data); };
    ffmpeg.OutputDataReceived += (_, _) => { };
    ffmpeg.Start();
    ffmpeg.BeginErrorReadLine();
    ffmpeg.BeginOutputReadLine();

    int frames = (int)Math.Round(seconds * fps);
    var writers = new List<Task>
    {
        Task.Run(() =>
        {
            using var fs = new FileStream(videoFifo, FileMode.Open, FileAccess.Write);
            int bpp = pf == VideoPixelFormat.Nv12 ? 0 : 4;
            var frame = new byte[pf == VideoPixelFormat.Nv12 ? w * h * 3 / 2 : w * h * 4];
            for (int i = 0; i < frames; i++)
            {
                bool flash = i == (int)Math.Round(flashAt * fps);
                FillFrame(frame, pf, w, h, i, flash);
                fs.Write(frame);
            }
        }),
    };
    for (int k = 0; k < audio.Length; k++)
    {
        SyntheticAudio a = audio[k];
        string fifo = audioFifos[k];
        writers.Add(Task.Run(() =>
        {
            using var fs = new FileStream(fifo, FileMode.Open, FileAccess.Write);
            var tl = new AudioTimeline(a.Rate);
            int packet = a.Rate / 100;
            long total = (long)Math.Round(seconds * a.Rate);
            for (long pos = 0; pos < total; pos += packet)
            {
                double t = pos / (double)a.Rate;
                if (t >= a.GapFrom && t < a.GapTo)
                    continue; // device sent nothing
                int n = (int)Math.Min(packet, total - pos);
                var samples = new float[n * 2];
                for (int j = 0; j < n; j++)
                {
                    double ts = (pos + j) / (double)a.Rate;
                    float v = ts >= a.BeepAt && ts < a.BeepAt + 0.2 ? (float)(0.8 * Math.Sin(2 * Math.PI * 1000 * ts)) : 0f;
                    samples[j * 2] = samples[j * 2 + 1] = v;
                }
                tl.Write(samples, n, pos, fs);
            }
            tl.PadTo(total, fs);
        }));
    }

    var all = Task.WhenAll(writers);
    if (await Task.WhenAny(all, Task.Delay(TimeSpan.FromMinutes(2))) != all)
    {
        ffmpeg.Kill(true);
        Console.WriteLine("      writers timed out\n" + log);
        return false;
    }
    await ffmpeg.WaitForExitAsync();
    if (ffmpeg.ExitCode != 0)
        Console.WriteLine($"      ffmpeg exited {ffmpeg.ExitCode}:\n      {FfmpegArgs.ForLog(args)}\n{log}");
    else if (log.Length > 0)
        Console.WriteLine("      ffmpeg said: " + log.ToString().Trim().Replace("\n", "\n      "));
    return ffmpeg.ExitCode == 0;
}

static void FillFrame(byte[] frame, VideoPixelFormat pf, int w, int h, int index, bool flash)
{
    // Dark frame with a moving grey bar; one pure white frame as the sync marker.
    int barX = index * 7 % w;
    if (pf == VideoPixelFormat.Nv12)
    {
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                frame[y * w + x] = flash ? (byte)235 : (byte)(Math.Abs(x - barX) < 20 ? 120 : 20);
        Array.Fill(frame, (byte)128, w * h, w * h / 2);
    }
    else
    {
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                byte v = flash ? (byte)255 : (byte)(Math.Abs(x - barX) < 20 ? 120 : 10);
                int o = (y * w + x) * 4;
                frame[o] = frame[o + 1] = frame[o + 2] = v;
                frame[o + 3] = 255;
            }
    }
}

// =====================================================================
// Helpers
// =====================================================================

static bool CommandExists(string name)
{
    try
    {
        using var p = Process.Start(new ProcessStartInfo(name, "-version") { RedirectStandardOutput = true, RedirectStandardError = true });
        p!.WaitForExit(10000);
        return p.ExitCode == 0;
    }
    catch
    {
        return false;
    }
}

static void MakeFifo(string path)
{
    using var p = Process.Start("mkfifo", path)!;
    p.WaitForExit();
    if (p.ExitCode != 0)
        throw new IOException($"mkfifo {path} failed");
}

static async Task<JsonElement> ProbeAsync(string file)
{
    var psi = new ProcessStartInfo("ffprobe") { RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (string a in new[] { "-v", "error", "-show_streams", "-show_format", "-of", "json", file })
        psi.ArgumentList.Add(a);
    using var p = Process.Start(psi)!;
    string json = await p.StandardOutput.ReadToEndAsync();
    await p.WaitForExitAsync();
    return JsonDocument.Parse(json).RootElement.Clone();
}

static async Task<byte[]> DecodeAsync(params string[] args)
{
    var psi = new ProcessStartInfo("ffmpeg") { RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (string a in args)
        psi.ArgumentList.Add(a);
    using var p = Process.Start(psi)!;
    using var ms = new MemoryStream();
    Task err = p.StandardError.ReadToEndAsync();
    await p.StandardOutput.BaseStream.CopyToAsync(ms);
    await p.WaitForExitAsync();
    await err;
    return ms.ToArray();
}

static async Task<double> FirstBrightFrameAsync(string file)
{
    // Per-frame presentation time and average brightness, straight from the decoded stream.
    var psi = new ProcessStartInfo("ffprobe") { RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (string a in new[] { "-v", "error", "-f", "lavfi", "-i", $"movie={file},signalstats",
                 "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0" })
        psi.ArgumentList.Add(a);
    using var p = Process.Start(psi)!;
    string text = await p.StandardOutput.ReadToEndAsync();
    await p.WaitForExitAsync();
    foreach (string line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
    {
        string[] parts = line.Split(',');
        if (parts.Length >= 2 && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double pts) &&
            double.TryParse(parts[^1], NumberStyles.Float, CultureInfo.InvariantCulture, out double yavg) && yavg > 200)
            return pts;
    }
    return -1;
}

static async Task<double> FirstLoudSampleAsync(string file, int audioTrack)
{
    byte[] raw = await DecodeAsync("-v", "error", "-i", file, "-map", $"0:a:{audioTrack}", "-ac", "1", "-ar", "48000", "-f", "f32le", "-");
    var samples = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, float>(raw);
    for (int i = 0; i < samples.Length; i++)
    {
        if (Math.Abs(samples[i]) > 0.3)
            return i / 48000.0;
    }
    return -1;
}

internal sealed record SyntheticAudio(string Title, int Rate, double BeepAt, double GapFrom, double GapTo);

internal sealed class CountingStream : Stream
{
    public long Bytes { get; private set; }
    public override void Write(byte[] buffer, int offset, int count) => Bytes += count;
    public override void Write(ReadOnlySpan<byte> buffer) => Bytes += buffer.Length;
    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => Bytes;
    public override long Position { get => Bytes; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}
