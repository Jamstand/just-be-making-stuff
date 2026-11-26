using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Recshot.Core;

/// <summary>Everything the user can change, saved as JSON in %APPDATA%\Recshot\settings.json.</summary>
public sealed class AppSettings
{
    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Recshot", "settings.json");

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    // Capture
    public SourceKind Source { get; set; } = SourceKind.Display;
    public string? DisplayDevice { get; set; }
    public string? RegionDisplayDevice { get; set; }
    public int RegionX { get; set; }
    public int RegionY { get; set; }
    public int RegionWidth { get; set; }
    public int RegionHeight { get; set; }
    public bool ShowCursor { get; set; } = true;
    public bool HighlightClicks { get; set; } = true;

    // Video
    public int Fps { get; set; } = 60;
    public int MaxHeight { get; set; }
    public QualityPreset Quality { get; set; } = QualityPreset.High;
    public string? EncoderId { get; set; }
    public bool SaveAsMp4 { get; set; } = true;

    // Audio
    public bool SystemAudio { get; set; } = true;
    public string? SystemAudioDevice { get; set; }
    public int SystemVolume { get; set; } = 100;
    public bool Microphone { get; set; } = true;
    public string? MicrophoneDevice { get; set; }
    public int MicrophoneVolume { get; set; } = 100;

    // Webcam
    public bool Webcam { get; set; }
    public string? WebcamDevice { get; set; }
    public WebcamCorner WebcamCorner { get; set; } = WebcamCorner.BottomRight;
    public int WebcamSizePercent { get; set; } = 24;
    public WebcamShape WebcamShape { get; set; } = WebcamShape.Circle;
    public bool WebcamMirror { get; set; } = true;

    // Replay buffer
    public bool ReplayEnabled { get; set; }
    public int ReplaySeconds { get; set; } = 30;

    // Saving
    public string VideoFolder { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "Recshot");
    public string ScreenshotFolder { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Recshot");
    public bool CopyScreenshotToClipboard { get; set; } = true;
    public bool HideFromCapture { get; set; } = true;

    // Hotkeys
    public string HotkeyRecord { get; set; } = "Ctrl+Shift+F9";
    public string HotkeyPause { get; set; } = "Ctrl+Shift+F10";
    public string HotkeySaveReplay { get; set; } = "Ctrl+Shift+F11";
    public string HotkeyScreenshot { get; set; } = "Ctrl+Shift+F12";

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Json) ?? new AppSettings();
        }
        catch (Exception ex)
        {
            Log.Warn($"Settings unreadable, using defaults: {ex.Message}");
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch (Exception ex)
        {
            Log.Warn($"Couldn't save settings: {ex.Message}");
        }
    }
}
