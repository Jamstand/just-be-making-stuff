using System.IO;
using System.Windows.Threading;
using Recshot.Encode;

namespace Recshot.Core;

/// <summary>
/// Owns the capture pipeline and the two things that can hang off it: a recording and the replay
/// buffer. All public methods are safe to call from the UI thread; events are raised on the UI thread.
/// </summary>
internal sealed class RecorderEngine
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dispatcher _ui;
    private CapturePipeline? _pipeline;
    private EncodeSession? _recording;
    private EncodeSession? _replay;
    private string? _replayDir;
    private int _replaySeconds;
    private bool _recordingAsMp4;

    public RecorderEngine(Dispatcher ui) => _ui = ui;

    public string? FfmpegPath { get; set; }
    public bool IsRecording => _recording != null;
    public bool IsPaused => _recording?.IsPaused == true;
    public bool IsReplayRunning => _replay != null;
    public bool IsBusy { get; private set; }
    public TimeSpan RecordingElapsed => _recording?.Elapsed ?? TimeSpan.Zero;
    public CapturePipeline? Pipeline => _pipeline;
    public string? ActiveOutputSize => _pipeline == null ? null : $"{_pipeline.Video.Width}×{_pipeline.Video.Height} @ {_pipeline.Video.Fps} fps";

    public event Action? StateChanged;
    public event Action<string>? Notice;
    public event Action<string>? ErrorOccurred;

    // ---------------- recording ----------------

    public async Task StartRecordingAsync(PipelineConfig cfg, string folder, bool asMp4)
    {
        await RunExclusiveAsync(async () =>
        {
            if (_recording != null)
                return;
            string ffmpeg = RequireFfmpeg();
            await EnsurePipelineAsync(cfg);

            Directory.CreateDirectory(folder);
            string mkv = UniquePath(Path.Combine(folder, $"Recshot {DateTime.Now:yyyy-MM-dd HH-mm-ss}.mkv"));
            EncodeSession session = EncodeSession.StartRecording(_pipeline!, ffmpeg, mkv);
            session.Failed += OnSessionFailed;
            _recording = session;
            _recordingAsMp4 = asMp4;
            try
            {
                await session.WaitUntilRunningAsync(TimeSpan.FromSeconds(15));
            }
            catch
            {
                _recording = null;
                await session.StopAsync();
                Ffmpeg.TryDelete(mkv);
                ReleasePipelineIfIdle();
                throw;
            }
        });
    }

    /// <summary>Stops, finalises (MKV → MP4) and returns the saved file path.</summary>
    public async Task<string?> StopRecordingAsync()
    {
        string? result = null;
        await RunExclusiveAsync(async () => result = await StopRecordingCoreAsync());
        return result;
    }

    private async Task<string?> StopRecordingCoreAsync()
    {
        EncodeSession? session = _recording;
        if (session == null)
            return null;
        _recording = null;
        RaiseState();

        bool clean = await session.StopAsync();
        ReleasePipelineIfIdle();

        string mkv = session.OutputPath;
        if (!File.Exists(mkv) || new FileInfo(mkv).Length == 0)
        {
            Ffmpeg.TryDelete(mkv);
            throw new IOException("Nothing was recorded. " + session.LastError + $" (details: {session.LogPath})");
        }
        if (!clean)
            Log.Warn("Recording ended uncleanly; the MKV may be missing its last moments");

        if (!_recordingAsMp4)
            return mkv;

        string mp4 = UniquePath(Path.ChangeExtension(mkv, ".mp4"));
        try
        {
            RaiseNotice("Finishing the MP4…");
            await Ffmpeg.RemuxToMp4Async(RequireFfmpeg(), mkv, mp4, session.AudioTitles, session.Encoder.Codec);
            Ffmpeg.TryDelete(mkv);
            return mp4;
        }
        catch (Exception ex)
        {
            Log.Error("Remux failed", ex);
            RaiseNotice($"Kept the recording as MKV because the MP4 conversion failed: {ex.Message}");
            return mkv;
        }
    }

    public void TogglePause()
    {
        EncodeSession? session = _recording;
        if (session == null)
            return;
        if (session.IsPaused)
            session.Resume();
        else
            session.Pause();
        RaiseState();
    }

    // ---------------- replay buffer ----------------

    public async Task StartReplayAsync(PipelineConfig cfg, int seconds)
    {
        await RunExclusiveAsync(async () =>
        {
            if (_replay != null && _replaySeconds == seconds && (Matches(_pipeline?.Config, cfg) || _recording != null))
                return;
            if (_replay != null)
                await StopReplayCoreAsync();
            _replaySeconds = seconds;
            await EnsurePipelineAsync(cfg);
            await StartReplayCoreAsync();
        });
    }

    public async Task StopReplayAsync() => await RunExclusiveAsync(StopReplayCoreAsync);

    /// <summary>Saves the last N seconds and returns the MP4 path.</summary>
    public async Task<string> SaveReplayAsync(string folder)
    {
        EncodeSession session = _replay ?? throw new InvalidOperationException("Turn on the replay buffer first.");
        Directory.CreateDirectory(folder);
        string path = UniquePath(Path.Combine(folder, $"Replay {DateTime.Now:yyyy-MM-dd HH-mm-ss}.mp4"));
        await session.SaveReplayAsync(RequireFfmpeg(), path, _replaySeconds);
        return path;
    }

    private async Task StartReplayCoreAsync()
    {
        string ffmpeg = RequireFfmpeg();
        string dir = Path.Combine(Path.GetTempPath(), "Recshot", "replay", Guid.NewGuid().ToString("N")[..8]);
        EncodeSession session = EncodeSession.StartReplay(_pipeline!, ffmpeg, dir, _replaySeconds);
        session.Failed += OnSessionFailed;
        _replay = session;
        _replayDir = dir;
        try
        {
            await session.WaitUntilRunningAsync(TimeSpan.FromSeconds(15));
        }
        catch
        {
            await StopReplayCoreAsync();
            throw;
        }
        RaiseState();
    }

    private async Task StopReplayCoreAsync()
    {
        EncodeSession? session = _replay;
        string? dir = _replayDir;
        if (session == null)
            return;
        _replay = null;
        _replayDir = null;
        await session.StopAsync();
        ReleasePipelineIfIdle();
        if (dir != null)
            _ = Task.Run(() =>
            {
                try
                {
                    Directory.Delete(dir, recursive: true);
                }
                catch
                {
                }
            });
        RaiseState();
    }

    /// <summary>Clears replay leftovers from a previous run that didn't exit cleanly.</summary>
    public static void CleanStaleReplayFolders()
    {
        try
        {
            string root = Path.Combine(Path.GetTempPath(), "Recshot", "replay");
            if (Directory.Exists(root))
                Directory.Delete(root, recursive: true);
        }
        catch
        {
        }
    }

    // ---------------- pipeline ----------------

    private async Task EnsurePipelineAsync(PipelineConfig cfg)
    {
        if (_pipeline != null)
        {
            if (Matches(_pipeline.Config, cfg))
            {
                // Volume is applied live and never needs a restart.
                if (_pipeline.SystemAudio != null && cfg.SystemAudio != null)
                    _pipeline.SystemAudio.Gain = cfg.SystemAudio.Gain;
                if (_pipeline.Microphone != null && cfg.Microphone != null)
                    _pipeline.Microphone.Gain = cfg.Microphone.Gain;
                return;
            }
            if (_recording != null)
                return; // Can't swap sources mid-recording; the replay buffer keeps using the current ones.

            // Only the replay buffer is running: restart it with the new settings.
            bool hadReplay = _replay != null;
            if (hadReplay)
                await StopReplayCoreAsync();
            DisposePipeline();
            await CreatePipelineAsync(cfg);
            if (hadReplay)
            {
                await StartReplayCoreAsync();
                RaiseNotice("Replay buffer restarted with the new settings.");
            }
            return;
        }
        await CreatePipelineAsync(cfg);
    }

    private async Task CreatePipelineAsync(PipelineConfig cfg)
    {
        CapturePipeline pipeline = await CapturePipeline.StartAsync(cfg, _ui);
        pipeline.Faulted += msg => _ui.BeginInvoke(() => _ = HandlePipelineFaultAsync(pipeline, msg));
        pipeline.Warning += RaiseNotice;
        _pipeline = pipeline;
        foreach (string warning in pipeline.Warnings)
            RaiseNotice(warning);
    }

    private async Task HandlePipelineFaultAsync(CapturePipeline pipeline, string message)
    {
        if (pipeline != _pipeline)
            return;
        await RunExclusiveAsync(async () =>
        {
            if (pipeline != _pipeline)
                return;
            string? saved = null;
            try
            {
                saved = await StopRecordingCoreAsync();
            }
            catch (Exception ex)
            {
                Log.Error("Stopping after a capture fault failed", ex);
            }
            await StopReplayCoreAsync();
            DisposePipeline();
            RaiseError(saved != null ? $"{message} The recording so far was saved to {saved}." : message);
        });
    }

    private void OnSessionFailed(EncodeSession session, string message)
    {
        _ui.BeginInvoke(async () =>
        {
            try
            {
                await RunExclusiveAsync(async () =>
                {
                    if (session == _recording)
                    {
                        string? saved = null;
                        try
                        {
                            saved = await StopRecordingCoreAsync();
                        }
                        catch (Exception ex)
                        {
                            Log.Error("Salvaging failed recording", ex);
                        }
                        RaiseError($"Recording stopped: {message}" + (saved != null ? $" What was captured was saved to {saved}." : ""));
                    }
                    else if (session == _replay)
                    {
                        await StopReplayCoreAsync();
                        RaiseError($"Replay buffer stopped: {message}");
                    }
                });
            }
            catch (Exception ex)
            {
                Log.Error("Session failure handling", ex);
            }
        });
    }

    private void ReleasePipelineIfIdle()
    {
        if (_recording == null && _replay == null)
            DisposePipeline();
    }

    private void DisposePipeline()
    {
        CapturePipeline? p = _pipeline;
        _pipeline = null;
        if (p == null)
            return;
        try
        {
            p.Dispose();
        }
        catch (Exception ex)
        {
            Log.Error("Pipeline dispose", ex);
        }
    }

    public async Task ShutdownAsync()
    {
        await RunExclusiveAsync(async () =>
        {
            await StopReplayCoreAsync();
            DisposePipeline();
        });
    }

    // ---------------- helpers ----------------

    /// <summary>Same capture settings, ignoring volume levels (those change live).</summary>
    private static bool Matches(PipelineConfig? a, PipelineConfig? b)
    {
        if (a == null || b == null)
            return false;
        static PipelineConfig Normalize(PipelineConfig c) => c with
        {
            SystemAudio = c.SystemAudio == null ? null : c.SystemAudio with { Gain = 1 },
            Microphone = c.Microphone == null ? null : c.Microphone with { Gain = 1 },
        };
        return Normalize(a) == Normalize(b);
    }

    private async Task RunExclusiveAsync(Func<Task> action)
    {
        await _gate.WaitAsync();
        IsBusy = true;
        RaiseState();
        try
        {
            await action();
        }
        finally
        {
            IsBusy = false;
            _gate.Release();
            RaiseState();
        }
    }

    private string RequireFfmpeg()
        => FfmpegPath ?? throw new InvalidOperationException("FFmpeg wasn't found. Put ffmpeg.exe next to Recshot.exe (the release zip already has it).");

    private static string UniquePath(string path)
    {
        if (!File.Exists(path))
            return path;
        string dir = Path.GetDirectoryName(path)!, name = Path.GetFileNameWithoutExtension(path), ext = Path.GetExtension(path);
        for (int i = 2; ; i++)
        {
            string candidate = Path.Combine(dir, $"{name} ({i}){ext}");
            if (!File.Exists(candidate))
                return candidate;
        }
    }

    private void RaiseState() => Post(() => StateChanged?.Invoke());
    private void RaiseNotice(string message) => Post(() => Notice?.Invoke(message));
    private void RaiseError(string message) => Post(() => ErrorOccurred?.Invoke(message));

    private void Post(Action action)
    {
        if (_ui.CheckAccess())
            action();
        else
            _ui.BeginInvoke(action);
    }
}
