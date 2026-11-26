using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using Recshot.Audio;
using Recshot.Capture;
using Recshot.Core;

namespace Recshot.Encode;

/// <summary>
/// One running FFmpeg encode. Raw NV12 frames and one raw float stream per audio source are written
/// into named pipes; FFmpeg encodes (NVENC etc.), mixes the audio and muxes.
///
/// Timing: the video gets exactly one frame per frame-slot of wall-clock time (see VideoPipeline), and
/// each audio stream is placed on the same clock by <see cref="AudioTimeline"/>. Pausing stops feeding
/// both, so the file stays one continuous recording without a gap.
/// </summary>
internal sealed class EncodeSession : IVideoSink
{
    private const double AudioCushionSeconds = 0.200;
    private const long MaxQueuedVideoBytes = 512L * 1024 * 1024;

    private readonly record struct QueuedFrame(FrameBuffer Frame, bool Fresh);

    private sealed class AudioTrack
    {
        public required AudioCaptureSource Source { get; init; }
        public required NamedPipeServerStream Pipe { get; init; }
        public required AudioTimeline Timeline { get; init; }
        public ConcurrentQueue<(AudioPacket Packet, long Expected)> Queue { get; } = new();
        public Action<AudioPacket>? Handler { get; set; }
        public Thread? Thread { get; set; }
    }

    private readonly CapturePipeline _pipeline;
    private readonly Process _ffmpeg;
    private readonly NamedPipeServerStream _videoPipe;
    private readonly BlockingCollection<QueuedFrame> _videoQueue = new();
    private readonly Thread _videoThread;
    private readonly AudioTrack[] _tracks;
    private readonly int _maxPendingFresh;
    private readonly object _videoGate = new();
    private readonly object _clock = new();
    private readonly long _start;
    private readonly StreamWriter? _logWriter;
    private readonly Queue<string> _lastErrors = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly TaskCompletionSource<bool> _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _connections;

    private long _pausedTotal;
    private long _pauseStart;
    private bool _paused;
    private bool _stopping;
    private long _stopAt;
    private volatile bool _stopRequested;
    private volatile bool _failed;
    private int _pendingFresh;
    private FrameBuffer? _lastQueued;

    public SessionKind Kind { get; }
    public string OutputPath { get; }
    public string? ReplayListPath { get; }
    public string LogPath { get; }
    public EncoderInfo Encoder { get; }
    public IReadOnlyList<string> AudioTitles { get; }
    public long DroppedFrames { get; private set; }
    public bool IsPaused { get { lock (_clock) return _paused; } }

    /// <summary>Raised once if FFmpeg dies or stops accepting data.</summary>
    public event Action<EncodeSession, string>? Failed;

    public TimeSpan Elapsed => TimeSpan.FromSeconds(ActiveTicksAt(Stopwatch.GetTimestamp()) / (double)Stopwatch.Frequency);

    private EncodeSession(SessionKind kind, CapturePipeline pipeline, string ffmpegPath, string outputPath, int replaySeconds)
    {
        Kind = kind;
        _pipeline = pipeline;
        Encoder = pipeline.Config.Encoder.Encoder;
        OutputPath = outputPath;
        VideoPipeline video = pipeline.Video;

        string id = $"recshot-{Environment.ProcessId}-{Guid.NewGuid():N}"[..36];
        _videoPipe = CreatePipe(id + "-v", Math.Min(video.Width * video.Height * 4, 32 * 1024 * 1024));
        _tracks = pipeline.Audio.Select((src, i) => new AudioTrack
        {
            Source = src,
            Pipe = CreatePipe($"{id}-a{i}", 1024 * 1024),
            Timeline = new AudioTimeline(src.SampleRate),
        }).ToArray();

        int frameBytes = video.PixelFormat == VideoPixelFormat.Nv12 ? video.Width * video.Height * 3 / 2 : video.Width * video.Height * 4;
        _maxPendingFresh = (int)Math.Clamp(MaxQueuedVideoBytes / frameBytes, 4, video.Fps * 2);

        if (kind == SessionKind.Replay)
        {
            Directory.CreateDirectory(outputPath);
            ReplayListPath = Path.Combine(outputPath, "segments.csv");
        }
        var audioInputs = _tracks.Select((t, i) => new FfmpegArgs.AudioInput(PipePath($"{id}-a{i}"), t.Source.SampleRate, t.Source.Name)).ToList();
        AudioTitles = FfmpegArgs.AudioTitles(audioInputs);
        List<string> args = FfmpegArgs.Build(
            kind,
            new FfmpegArgs.VideoInput(PipePath(id + "-v"), video.PixelFormat, video.Width, video.Height, video.Fps),
            audioInputs, Encoder, pipeline.Config.Encoder.Quality, outputPath, ReplayListPath, replaySeconds);

        LogPath = Path.Combine(Log.Directory, $"ffmpeg-{kind.ToString().ToLowerInvariant()}-{DateTime.Now:yyyyMMdd-HHmmss}.log");
        try
        {
            _logWriter = new StreamWriter(LogPath, append: false) { AutoFlush = true };
            _logWriter.WriteLine(FfmpegArgs.ForLog(args));
        }
        catch
        {
            _logWriter = null;
        }

        _ffmpeg = new Process { StartInfo = Ffmpeg.StartInfo(ffmpegPath, args), EnableRaisingEvents = true };
        _ffmpeg.ErrorDataReceived += OnFfmpegOutput;
        _ffmpeg.OutputDataReceived += OnFfmpegOutput;
        _ffmpeg.Exited += OnFfmpegExited;
        _ffmpeg.Start();
        _ffmpeg.BeginErrorReadLine();
        _ffmpeg.BeginOutputReadLine();
        try
        {
            _ffmpeg.PriorityClass = ProcessPriorityClass.AboveNormal;
        }
        catch
        {
        }

        // The session clock starts now; frames and audio queue up until FFmpeg has opened the pipes.
        _start = Stopwatch.GetTimestamp();

        _videoThread = new Thread(VideoLoop) { Name = $"Recshot {kind} video", IsBackground = true, Priority = ThreadPriority.AboveNormal };
        _videoThread.Start();
        foreach (AudioTrack t in _tracks)
        {
            AudioTrack track = t;
            track.Handler = p => OnAudio(track, p);
            track.Source.PacketArrived += track.Handler;
            track.Thread = new Thread(() => AudioLoop(track)) { Name = $"Recshot {kind} {track.Source.Name}", IsBackground = true };
            track.Thread.Start();
        }
        video.AddSink(this);
        Log.Info($"{kind} session started → {outputPath}");
    }

    private static string PipePath(string name) => $@"\\.\pipe\{name}";

    private static NamedPipeServerStream CreatePipe(string name, int bufferSize)
        => new(name, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, bufferSize);

    public static EncodeSession StartRecording(CapturePipeline pipeline, string ffmpegPath, string mkvPath)
        => new(SessionKind.Recording, pipeline, ffmpegPath, mkvPath, 0);

    public static EncodeSession StartReplay(CapturePipeline pipeline, string ffmpegPath, string segmentDir, int seconds)
        => new(SessionKind.Replay, pipeline, ffmpegPath, segmentDir, seconds);

    /// <summary>Completes once FFmpeg has opened every input, or throws with FFmpeg's error if it quit.</summary>
    public async Task WaitUntilRunningAsync(TimeSpan timeout)
    {
        Task done = await Task.WhenAny(_started.Task, Task.Delay(timeout));
        if (done != _started.Task)
            throw new TimeoutException("FFmpeg took too long to start. " + LastError);
        await _started.Task;
    }

    public string LastError
    {
        get
        {
            lock (_lastErrors)
                return string.Join(" ", _lastErrors);
        }
    }

    // ---------------- video ----------------

    public void OnVideoFrame(FrameBuffer frame, int repeat)
    {
        lock (_clock)
        {
            if (_paused || _stopping)
                return;
        }

        lock (_videoGate)
        {
            if (_videoQueue.IsAddingCompleted)
                return;

            // If FFmpeg falls behind, repeat the last queued frame rather than holding ever more new ones in memory.
            FrameBuffer chosen;
            bool fresh;
            if (_lastQueued == null || (frame != _lastQueued && Volatile.Read(ref _pendingFresh) < _maxPendingFresh))
            {
                chosen = frame;
                fresh = frame != _lastQueued;
            }
            else
            {
                chosen = _lastQueued;
                fresh = false;
                if (frame != _lastQueued)
                    DroppedFrames++;
            }

            for (int i = 0; i < repeat; i++)
            {
                bool isFresh = fresh && i == 0;
                chosen.AddRef();
                if (isFresh)
                    Interlocked.Increment(ref _pendingFresh);
                try
                {
                    _videoQueue.Add(new QueuedFrame(chosen, isFresh));
                }
                catch (InvalidOperationException)
                {
                    chosen.Release();
                    if (isFresh)
                        Interlocked.Decrement(ref _pendingFresh);
                    return;
                }
            }

            if (chosen != _lastQueued)
            {
                chosen.AddRef();
                _lastQueued?.Release();
                _lastQueued = chosen;
            }
        }
    }

    private void VideoLoop()
    {
        bool connected = WaitForConnection(_videoPipe);
        foreach (QueuedFrame q in _videoQueue.GetConsumingEnumerable())
        {
            try
            {
                if (connected && !_failed)
                    _videoPipe.Write(q.Frame.Data, 0, q.Frame.Data.Length);
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException)
            {
                Fail($"FFmpeg stopped accepting video. {LastError}");
            }
            finally
            {
                if (q.Fresh)
                    Interlocked.Decrement(ref _pendingFresh);
                q.Frame.Release();
            }
        }
        ClosePipe(_videoPipe);
    }

    private bool WaitForConnection(NamedPipeServerStream pipe)
    {
        try
        {
            Task wait = pipe.WaitForConnectionAsync(_cts.Token);
            while (!wait.Wait(100))
            {
                if (_ffmpeg.HasExited || _stopRequested)
                    return false;
            }
            if (Interlocked.Increment(ref _connections) == 1 + _tracks.Length)
                _started.TrySetResult(true);
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"Pipe connection failed: {ex.GetBaseException().Message}");
            return false;
        }
    }

    // ---------------- audio ----------------

    private void OnAudio(AudioTrack track, AudioPacket packet)
    {
        long active;
        lock (_clock)
        {
            if (_paused || _stopping)
                return;
            active = packet.Timestamp - _start - _pausedTotal;
        }
        int rate = track.Timeline.SampleRate;
        double startSeconds = active / (double)Stopwatch.Frequency - packet.Frames / (double)rate;
        track.Queue.Enqueue((packet, (long)Math.Round(startSeconds * rate)));
    }

    private void AudioLoop(AudioTrack track)
    {
        bool connected = WaitForConnection(track.Pipe);
        AudioTimeline timeline = track.Timeline;
        long cushion = (long)(timeline.SampleRate * AudioCushionSeconds);

        try
        {
            while (connected && !_failed)
            {
                bool finishing = _stopRequested;
                while (track.Queue.TryDequeue(out var item))
                    timeline.Write(item.Packet.Samples, item.Packet.Frames, item.Expected, track.Pipe);

                // Keep the stream moving in real time even while the device sends nothing.
                long target = finishing
                    ? ActiveTicksAt(_stopAt) * timeline.SampleRate / Stopwatch.Frequency
                    : ActiveTicksAt(Stopwatch.GetTimestamp()) * timeline.SampleRate / Stopwatch.Frequency - cushion;
                timeline.PadTo(target, track.Pipe);

                if (finishing)
                    break;
                Thread.Sleep(10);
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Fail($"FFmpeg stopped accepting {track.Source.Name.ToLowerInvariant()}. {LastError}");
        }
        finally
        {
            if (timeline.InsertedSilence > 0 || timeline.DroppedFrames > 0)
                Log.Info($"{Kind} {track.Source.Name}: padded {timeline.InsertedSilence} and trimmed {timeline.DroppedFrames} sample frames to stay in sync");
            ClosePipe(track.Pipe);
        }
    }

    // ---------------- clock / control ----------------

    private long ActiveTicksAt(long timestamp)
    {
        lock (_clock)
        {
            if (_paused)
                timestamp = _pauseStart;
            if (_stopping && timestamp > _stopAt)
                timestamp = _stopAt;
            return Math.Max(0, timestamp - _start - _pausedTotal);
        }
    }

    public void Pause()
    {
        lock (_clock)
        {
            if (_paused || _stopping)
                return;
            _paused = true;
            _pauseStart = Stopwatch.GetTimestamp();
        }
        Log.Info($"{Kind} paused");
    }

    public void Resume()
    {
        lock (_clock)
        {
            if (!_paused || _stopping)
                return;
            _pausedTotal += Stopwatch.GetTimestamp() - _pauseStart;
            _paused = false;
        }
        Log.Info($"{Kind} resumed");
    }

    /// <summary>Stops feeding FFmpeg, lets it finish the file, and returns true if it exited cleanly.</summary>
    public async Task<bool> StopAsync()
    {
        lock (_clock)
        {
            if (_stopping)
                return false;
            _stopAt = _paused ? _pauseStart : Stopwatch.GetTimestamp();
            _stopping = true;
        }
        _stopRequested = true;

        _pipeline.Video.RemoveSink(this);
        foreach (AudioTrack t in _tracks)
        {
            if (t.Handler != null)
                t.Source.PacketArrived -= t.Handler;
        }
        lock (_videoGate)
        {
            _videoQueue.CompleteAdding();
            _lastQueued?.Release();
            _lastQueued = null;
        }

        await Task.Run(() =>
        {
            _videoThread.Join();
            foreach (AudioTrack t in _tracks)
                t.Thread?.Join();
        });
        _cts.Cancel();

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        try
        {
            await _ffmpeg.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            Log.Warn("FFmpeg didn't exit in time; killing it");
            try
            {
                _ffmpeg.Kill(entireProcessTree: true);
            }
            catch
            {
            }
        }

        bool ok = _ffmpeg.HasExited && _ffmpeg.ExitCode == 0 && !_failed;
        Log.Info($"{Kind} session ended (exit {(_ffmpeg.HasExited ? _ffmpeg.ExitCode : -1)}, frames repeated because the encoder was behind: {DroppedFrames})");
        try
        {
            _logWriter?.Dispose();
        }
        catch
        {
        }
        _ffmpeg.Dispose();
        return ok;
    }

    private static void ClosePipe(NamedPipeServerStream pipe)
    {
        try
        {
            if (pipe.IsConnected)
                pipe.Flush();
        }
        catch
        {
        }
        try
        {
            pipe.Dispose();
        }
        catch
        {
        }
    }

    private void OnFfmpegOutput(object sender, DataReceivedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(e.Data))
            return;
        try
        {
            _logWriter?.WriteLine(e.Data);
        }
        catch
        {
        }
        lock (_lastErrors)
        {
            _lastErrors.Enqueue(e.Data.Trim());
            while (_lastErrors.Count > 4)
                _lastErrors.Dequeue();
        }
    }

    private void OnFfmpegExited(object? sender, EventArgs e)
    {
        if (_stopRequested)
            return;
        // Give stderr a moment to drain so the message is useful.
        Task.Delay(300).ContinueWith(_ => Fail($"FFmpeg quit unexpectedly. {LastError}"));
    }

    private void Fail(string message)
    {
        if (_failed)
            return;
        _failed = true;
        Log.Error($"{Kind} session failed: {message}");
        _started.TrySetException(new InvalidOperationException(message));
        if (!_stopRequested)
            Failed?.Invoke(this, message);
    }

    // ---------------- replay buffer ----------------

    /// <summary>
    /// Writes the last <paramref name="seconds"/> of the replay buffer to <paramref name="outputPath"/> (MP4).
    /// Waits briefly for the segment containing "now" to be finished so the clip ends at the key press.
    /// </summary>
    public async Task SaveReplayAsync(string ffmpegPath, string outputPath, int seconds)
    {
        if (Kind != SessionKind.Replay || ReplayListPath == null)
            throw new InvalidOperationException("Not a replay session.");

        double requested = Elapsed.TotalSeconds;
        var deadline = DateTime.UtcNow.AddSeconds(3.5);
        List<ReplaySegments.Segment> segments;
        while (true)
        {
            segments = ReplaySegments.Read(ReplayListPath);
            if (segments.Count > 0 && segments[^1].End >= requested - 0.05)
                break;
            if (DateTime.UtcNow > deadline)
                break;
            await Task.Delay(100);
        }
        List<ReplaySegments.Segment> chosen = ReplaySegments.LastSeconds(segments, seconds);
        if (chosen.Count == 0)
            throw new InvalidOperationException("The replay buffer is still filling up. Try again in a couple of seconds.");

        // Segment names are relative to the segment folder, which keeps the command line short.
        string segmentDir = Path.GetDirectoryName(ReplayListPath)!;
        var names = chosen.Select(s => Path.GetFileName(s.Path)).ToList();
        var (code, output) = await Ffmpeg.RunAsync(ffmpegPath,
            FfmpegArgs.ConcatToMp4(names, outputPath, AudioTitles, Encoder.Codec), TimeSpan.FromMinutes(2), segmentDir);
        if (code != 0 || !File.Exists(outputPath))
        {
            Ffmpeg.TryDelete(outputPath);
            throw new IOException($"Saving the replay failed: {Ffmpeg.LastLines(output, 3)}");
        }
    }
}
