using Recshot.Native;

namespace Recshot.Core;

public enum SourceKind { Display, Window, Region }

public enum WebcamCorner { BottomRight, BottomLeft, TopRight, TopLeft }

public enum WebcamShape { Circle, RoundedRectangle }

public enum QualityPreset { Ultra, High, Medium, Low }

/// <summary>Raw frame layout handed to FFmpeg: NV12 when the GPU converts, BGRA as the fallback.</summary>
public enum VideoPixelFormat { Nv12, Bgra }

/// <summary>What to capture. All rectangles are in physical (per-monitor-DPI-aware) screen pixels.</summary>
public sealed record CaptureTarget(
    SourceKind Kind,
    IntPtr Monitor,
    RECT MonitorBounds,
    IntPtr Window,
    RECT Region,
    string Description);

/// <summary>A video encoder FFmpeg can drive. <paramref name="Id"/> is the FFmpeg encoder name, e.g. h264_nvenc.</summary>
public sealed record EncoderInfo(string Id, string Name, string Vendor, string Codec)
{
    public bool IsHardware => Vendor != "cpu";
    public override string ToString() => Name;
}

public sealed record WebcamOptions(string DeviceId, WebcamCorner Corner, double SizeFraction, WebcamShape Shape, bool Mirror);

public sealed record AudioOptions(string? DeviceId, float Gain);

public sealed record EncoderOptions(EncoderInfo Encoder, QualityPreset Quality);

/// <summary>
/// Everything that shapes the capture pipeline. Records compare by value, so the engine can tell
/// whether a running pipeline (e.g. the replay buffer) already matches the requested settings.
/// </summary>
public sealed record PipelineConfig(
    CaptureTarget Target,
    int Fps,
    int MaxHeight,
    bool ShowCursor,
    bool HighlightClicks,
    WebcamOptions? Webcam,
    AudioOptions? SystemAudio,
    AudioOptions? Microphone,
    EncoderOptions Encoder);
