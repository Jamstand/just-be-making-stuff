using System.Windows.Threading;
using Recshot.Audio;
using Recshot.Capture;

namespace Recshot.Core;

/// <summary>
/// The live sources for one set of settings: screen + overlays (as a constant-rate video stream) and
/// system/mic audio. Recording and the replay buffer both attach to the same pipeline as sinks.
/// </summary>
internal sealed class CapturePipeline : IDisposable
{
    private readonly WebcamSource? _webcam;
    private readonly ClickTracker? _clicks;
    private bool _disposed;

    public PipelineConfig Config { get; }
    public GpuDevice Gpu { get; }
    public VideoPipeline Video { get; }
    public IReadOnlyList<AudioCaptureSource> Audio { get; }
    public AudioCaptureSource? SystemAudio { get; }
    public AudioCaptureSource? Microphone { get; }

    /// <summary>Non-fatal problems found while starting (e.g. webcam busy), to show the user.</summary>
    public IReadOnlyList<string> Warnings { get; }

    /// <summary>Raised when capture can't go on (window closed, GPU lost).</summary>
    public event Action<string>? Faulted;

    /// <summary>Raised for problems the recording survives, e.g. a microphone unplugged mid-recording.</summary>
    public event Action<string>? Warning;

    private CapturePipeline(PipelineConfig config, GpuDevice gpu, VideoPipeline video, WebcamSource? webcam,
        ClickTracker? clicks, AudioCaptureSource? system, AudioCaptureSource? mic, List<string> warnings)
    {
        Config = config;
        Gpu = gpu;
        Video = video;
        _webcam = webcam;
        _clicks = clicks;
        SystemAudio = system;
        Microphone = mic;
        Audio = new[] { system, mic }.Where(a => a != null).Cast<AudioCaptureSource>().ToList();
        Warnings = warnings;
        video.Faulted += msg => Faulted?.Invoke(msg);
    }

    public static async Task<CapturePipeline> StartAsync(PipelineConfig cfg, Dispatcher ui)
    {
        var warnings = new List<string>();
        GpuDevice? gpu = null;
        WebcamSource? webcam = null;
        ClickTracker? clicks = null;
        VideoPipeline? video = null;
        AudioCaptureSource? system = null, mic = null;

        try
        {
            gpu = await Task.Run(() => new GpuDevice());

            if (cfg.Webcam != null)
            {
                try
                {
                    webcam = await WebcamSource.StartAsync(cfg.Webcam.DeviceId);
                }
                catch (Exception ex)
                {
                    Log.Error("Webcam failed", ex);
                    warnings.Add($"Webcam not available: {ex.Message}");
                }
            }

            if (cfg.HighlightClicks)
                clicks = new ClickTracker(ui);

            GpuDevice gpuLocal = gpu;
            WebcamSource? webcamLocal = webcam;
            ClickTracker? clicksLocal = clicks;
            video = await Task.Run(() => new VideoPipeline(gpuLocal, cfg, webcamLocal, clicksLocal));

            if (cfg.SystemAudio != null)
            {
                try
                {
                    system = await Task.Run(() => AudioCaptureSource.Create("System audio", true, cfg.SystemAudio.DeviceId, cfg.SystemAudio.Gain));
                }
                catch (Exception ex)
                {
                    Log.Error("System audio failed", ex);
                    warnings.Add($"System audio not available: {ex.Message}");
                }
            }
            if (cfg.Microphone != null)
            {
                try
                {
                    mic = await Task.Run(() => AudioCaptureSource.Create("Microphone", false, cfg.Microphone.DeviceId, cfg.Microphone.Gain));
                }
                catch (Exception ex)
                {
                    Log.Error("Microphone failed", ex);
                    warnings.Add($"Microphone not available: {ex.Message}. Check Windows privacy settings → Microphone.");
                }
            }

            var pipeline = new CapturePipeline(cfg, gpu, video, webcam, clicks, system, mic, warnings);
            // A device that disappears just goes silent in the recording (the audio timeline pads it).
            foreach (AudioCaptureSource source in pipeline.Audio)
                source.Stopped += msg => pipeline.Warning?.Invoke(msg + " The recording continues with silence on that track.");
            video.Start();
            return pipeline;
        }
        catch
        {
            system?.Dispose();
            mic?.Dispose();
            video?.Dispose();
            clicks?.Dispose();
            webcam?.Dispose();
            gpu?.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        foreach (AudioCaptureSource a in Audio)
            a.Dispose();
        Video.Dispose();
        _clicks?.Dispose();
        _webcam?.Dispose();
        Gpu.Dispose();
    }
}
