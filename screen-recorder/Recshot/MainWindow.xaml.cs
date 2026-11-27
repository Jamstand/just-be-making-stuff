using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Recshot.Audio;
using Recshot.Capture;
using Recshot.Core;
using Recshot.Encode;
using Recshot.Native;
using Recshot.UI;

namespace Recshot;

public partial class MainWindow : Window, IOverlayHost
{
    private const int HotkeyRecordId = 1, HotkeyPauseId = 2, HotkeyReplayId = 3, HotkeyShotId = 4, HotkeyOverlayId = 5, HotkeyMicId = 6;

    private sealed record Option<T>(string Label, T Value)
    {
        public override string ToString() => Label;
    }

    private sealed record DeviceItem(string? Id, string Name);

    private readonly AppSettings _settings = AppSettings.Load();
    private readonly RecorderEngine _engine;
    private readonly DispatcherTimer _uiTimer;
    private readonly DispatcherTimer _replayRestartTimer;
    private readonly List<Control> _lockedWhileRecording;
    private HotkeyManager? _hotkeys;
    private List<EncoderInfo> _encoders = new();
    private bool _loading = true;
    private bool _closeConfirmed;
    private string? _notice;
    private DateTime _noticeUntil;
    private bool _noticeIsError;
    private TrayIcon? _tray;
    private RecordingHud? _hud;
    private OverlayWindow? _overlay;
    private bool _micMuted;
    private bool _quitRequested;

    /// <summary>Set by App when launched with --background (e.g. at Windows sign-in).</summary>
    public bool StartHidden { get; set; }

    public MainWindow()
    {
        InitializeComponent();
        _engine = new RecorderEngine(Dispatcher);
        _engine.StateChanged += UpdateUi;
        _engine.Notice += msg => ShowNotice(msg, false);
        _engine.ErrorOccurred += msg =>
        {
            ShowNotice(msg, true);
            Toast.Show("Recshot", msg, isError: true);
        };

        _lockedWhileRecording =
        [
            SourceDisplay, SourceWindow, SourceRegion, DisplayCombo, WindowCombo, RefreshWindowsButton, PickRegionButton,
            ShowCursorCheck, ClicksCheck, ResolutionCombo, FpsCombo, QualityCombo, EncoderCombo, FormatCombo,
            SystemAudioCheck, SystemDeviceCombo, MicCheck, MicDeviceCombo,
            WebcamCheck, WebcamCombo, WebcamCornerCombo, WebcamSizeCombo, WebcamShapeCombo, WebcamMirrorCheck,
        ];

        _uiTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(200) };
        _uiTimer.Tick += (_, _) => Tick();
        _replayRestartTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(900) };
        _replayRestartTimer.Tick += async (_, _) =>
        {
            _replayRestartTimer.Stop();
            await ApplySettingsToReplayAsync();
        };

        SourceInitialized += (_, _) =>
        {
            _hotkeys = new HotkeyManager(this);
            ApplyHideFromCapture();
            Win32.UseDarkTitleBar(new WindowInteropHelper(this).Handle);
        };
        Loaded += async (_, _) =>
        {
            if (StartHidden)
                Hide();
            await InitializeAsync();
        };
        StateChanged += (_, _) =>
        {
            if (WindowState == WindowState.Minimized && _settings.CloseToTray)
                HideToTray();
        };
    }

    // =====================================================================
    // Startup
    // =====================================================================

    private async Task InitializeAsync()
    {
        _tray = new TrayIcon(
            ShowFromTray,
            () => _ = ToggleRecordingAsync(),
            TogglePause,
            () => ReplayCheck.IsChecked = ReplayCheck.IsChecked != true,
            () => _ = SaveReplayAsync(),
            () => _ = TakeScreenshotAsync(),
            () => OpenFolder(_settings.VideoFolder),
            QuitFromTray);
        PopulateStaticLists();
        RefreshDisplays();
        RefreshWindows();
        RefreshAudioDevices();
        LoadSettingsIntoControls();
        HookChangeHandlers();
        RegisterHotkeys();
        UpdateSourcePanels();
        _loading = false;
        _uiTimer.Start();
        UpdateUi();

        await RefreshWebcamsAsync();
        await ScreenCapture.RequestBorderlessAccessAsync();

        _engine.FfmpegPath = Ffmpeg.Locate();
        if (_engine.FfmpegPath == null)
        {
            EncoderHint.Text = "FFmpeg wasn't found. Put ffmpeg.exe in the same folder as Recshot.exe (the release zip already includes it).";
            EncoderHint.Foreground = Brushes.IndianRed;
            UpdateUi();
            return;
        }
        Log.Info($"FFmpeg: {_engine.FfmpegPath}");

        EncoderHint.Text = "Checking which encoders your PC supports…";
        _encoders = await EncoderCatalog.ProbeAsync(_engine.FfmpegPath);
        if (_encoders.Count == 0)
            _encoders.Add(EncoderCatalog.Software);
        _loading = true;
        EncoderCombo.ItemsSource = _encoders;
        EncoderCombo.SelectedItem = _encoders.FirstOrDefault(e => e.Id == _settings.EncoderId) ?? EncoderCatalog.PickDefault(_encoders);
        _loading = false;
        UpdateEncoderHint();
        UpdateUi();

        if (_settings.ReplayEnabled)
            await StartReplayAsync();
    }

    private void PopulateStaticLists()
    {
        ResolutionCombo.ItemsSource = new[]
        {
            new Option<int>("Native (sharpest)", 0),
            new Option<int>("2160p (4K)", 2160),
            new Option<int>("1440p", 1440),
            new Option<int>("1080p", 1080),
            new Option<int>("720p", 720),
        };
        FpsCombo.ItemsSource = new[] { 24, 30, 60, 120, 144 }.Select(f => new Option<int>($"{f} fps", f)).ToArray();
        QualityCombo.ItemsSource = new[]
        {
            new Option<QualityPreset>("Ultra", QualityPreset.Ultra),
            new Option<QualityPreset>("High", QualityPreset.High),
            new Option<QualityPreset>("Medium", QualityPreset.Medium),
            new Option<QualityPreset>("Small files", QualityPreset.Low),
        };
        FormatCombo.ItemsSource = new[] { new Option<bool>("MP4", true), new Option<bool>("MKV", false) };
        WebcamCornerCombo.ItemsSource = new[]
        {
            new Option<WebcamCorner>("Bottom right", WebcamCorner.BottomRight),
            new Option<WebcamCorner>("Bottom left", WebcamCorner.BottomLeft),
            new Option<WebcamCorner>("Top right", WebcamCorner.TopRight),
            new Option<WebcamCorner>("Top left", WebcamCorner.TopLeft),
        };
        WebcamSizeCombo.ItemsSource = new[]
        {
            new Option<int>("Small", 18),
            new Option<int>("Medium", 24),
            new Option<int>("Large", 32),
        };
        WebcamShapeCombo.ItemsSource = new[]
        {
            new Option<WebcamShape>("Circle", WebcamShape.Circle),
            new Option<WebcamShape>("Rounded box", WebcamShape.RoundedRectangle),
        };
        ReplayLengthCombo.ItemsSource = new[]
        {
            new Option<int>("15 seconds", 15),
            new Option<int>("30 seconds", 30),
            new Option<int>("1 minute", 60),
            new Option<int>("2 minutes", 120),
            new Option<int>("5 minutes", 300),
        };
    }

    private void RefreshDisplays()
    {
        string? selected = (DisplayCombo.SelectedItem as DisplayInfo)?.DeviceName ?? _settings.DisplayDevice;
        List<DisplayInfo> displays = ScreenInfo.GetDisplays();
        bool wasLoading = _loading;
        _loading = true;
        DisplayCombo.ItemsSource = displays;
        DisplayCombo.SelectedItem = displays.FirstOrDefault(d => d.DeviceName == selected)
                                    ?? displays.FirstOrDefault(d => d.IsPrimary) ?? displays.FirstOrDefault();
        _loading = wasLoading;
    }

    private void RefreshWindows()
    {
        IntPtr selected = (WindowCombo.SelectedItem as WindowInfo)?.Handle ?? IntPtr.Zero;
        IntPtr self = new WindowInteropHelper(this).Handle;
        List<WindowInfo> windows = ScreenInfo.GetWindows([self]);
        bool wasLoading = _loading;
        _loading = true;
        WindowCombo.ItemsSource = windows;
        WindowCombo.SelectedItem = windows.FirstOrDefault(w => w.Handle == selected) ?? windows.FirstOrDefault();
        _loading = wasLoading;
    }

    private void RefreshAudioDevices()
    {
        try
        {
            var outputs = new List<DeviceItem> { new(null, "Default output (speakers / headphones)") };
            outputs.AddRange(AudioCaptureSource.ListDevices(output: true).Select(d => new DeviceItem(d.Id, d.Name)));
            SystemDeviceCombo.ItemsSource = outputs;

            var inputs = new List<DeviceItem> { new(null, "Default microphone") };
            inputs.AddRange(AudioCaptureSource.ListDevices(output: false).Select(d => new DeviceItem(d.Id, d.Name)));
            MicDeviceCombo.ItemsSource = inputs;
        }
        catch (Exception ex)
        {
            Log.Error("Audio device listing failed", ex);
        }
    }

    private async Task RefreshWebcamsAsync()
    {
        try
        {
            var cams = (await WebcamSource.ListAsync()).Select(c => new DeviceItem(c.Id, c.Name)).ToList();
            bool wasLoading = _loading;
            _loading = true;
            WebcamCombo.ItemsSource = cams;
            WebcamCombo.SelectedItem = cams.FirstOrDefault(c => c.Id == _settings.WebcamDevice) ?? cams.FirstOrDefault();
            _loading = wasLoading;
            if (cams.Count == 0)
            {
                WebcamCheck.IsChecked = false;
                WebcamCheck.IsEnabled = false;
                WebcamCheck.Content = "No webcam found";
            }
        }
        catch (Exception ex)
        {
            Log.Error("Webcam listing failed", ex);
        }
    }

    private void LoadSettingsIntoControls()
    {
        AppSettings s = _settings;
        SourceDisplay.IsChecked = s.Source == SourceKind.Display;
        SourceWindow.IsChecked = s.Source == SourceKind.Window;
        SourceRegion.IsChecked = s.Source == SourceKind.Region;
        UpdateRegionText();
        ShowCursorCheck.IsChecked = s.ShowCursor;
        ClicksCheck.IsChecked = s.HighlightClicks;

        Select(ResolutionCombo, s.MaxHeight);
        Select(FpsCombo, s.Fps);
        Select(QualityCombo, s.Quality);
        Select(FormatCombo, s.SaveAsMp4);

        SystemAudioCheck.IsChecked = s.SystemAudio;
        SystemDeviceCombo.SelectedItem = (SystemDeviceCombo.ItemsSource as List<DeviceItem>)?.FirstOrDefault(d => d.Id == s.SystemAudioDevice)
                                         ?? (SystemDeviceCombo.ItemsSource as List<DeviceItem>)?.FirstOrDefault();
        SystemVolumeSlider.Value = s.SystemVolume;
        MicCheck.IsChecked = s.Microphone;
        MicDeviceCombo.SelectedItem = (MicDeviceCombo.ItemsSource as List<DeviceItem>)?.FirstOrDefault(d => d.Id == s.MicrophoneDevice)
                                      ?? (MicDeviceCombo.ItemsSource as List<DeviceItem>)?.FirstOrDefault();
        MicVolumeSlider.Value = s.MicrophoneVolume;

        WebcamCheck.IsChecked = s.Webcam;
        Select(WebcamCornerCombo, s.WebcamCorner);
        Select(WebcamSizeCombo, s.WebcamSizePercent);
        Select(WebcamShapeCombo, s.WebcamShape);
        WebcamMirrorCheck.IsChecked = s.WebcamMirror;

        ReplayCheck.IsChecked = s.ReplayEnabled;
        Select(ReplayLengthCombo, s.ReplaySeconds);

        VideoFolderBox.Text = s.VideoFolder;
        ShotFolderBox.Text = s.ScreenshotFolder;
        ClipboardCheck.IsChecked = s.CopyScreenshotToClipboard;
        HideSelfCheck.IsChecked = s.HideFromCapture;
        CloseToTrayCheck.IsChecked = s.CloseToTray;
        StartupCheck.IsChecked = s.StartWithWindows;

        HotkeyRecordBox.Text = s.HotkeyRecord;
        HotkeyPauseBox.Text = s.HotkeyPause;
        HotkeyReplayBox.Text = s.HotkeySaveReplay;
        HotkeyShotBox.Text = s.HotkeyScreenshot;
        HotkeyOverlayBox.Text = s.HotkeyOverlay;
        HotkeyMicBox.Text = s.HotkeyMicMute;
        UpdateVolumeLabels();
    }

    private static void Select<T>(ComboBox combo, T value)
    {
        var items = (combo.ItemsSource as IEnumerable<Option<T>>)?.ToList();
        if (items == null || items.Count == 0)
            return;
        combo.SelectedItem = items.FirstOrDefault(o => EqualityComparer<T>.Default.Equals(o.Value, value)) ?? items[0];
    }

    private static T? Selected<T>(ComboBox combo, T fallback) => combo.SelectedItem is Option<T> o ? o.Value : fallback;

    private void HookChangeHandlers()
    {
        foreach (RadioButton r in new[] { SourceDisplay, SourceWindow, SourceRegion })
            r.Checked += (_, _) => { UpdateSourcePanels(); OnSettingChanged(); };
        foreach (CheckBox c in new[] { ShowCursorCheck, ClicksCheck, SystemAudioCheck, MicCheck, WebcamCheck, WebcamMirrorCheck, ClipboardCheck, HideSelfCheck, CloseToTrayCheck, StartupCheck })
        {
            c.Checked += (_, _) => OnSettingChanged();
            c.Unchecked += (_, _) => OnSettingChanged();
        }
        foreach (ComboBox c in new[] { DisplayCombo, WindowCombo, ResolutionCombo, FpsCombo, QualityCombo, EncoderCombo, FormatCombo,
                     SystemDeviceCombo, MicDeviceCombo, WebcamCombo, WebcamCornerCombo, WebcamSizeCombo, WebcamShapeCombo })
            c.SelectionChanged += (_, _) => OnSettingChanged();

        SystemVolumeSlider.ValueChanged += (_, _) => OnVolumeChanged();
        MicVolumeSlider.ValueChanged += (_, _) => OnVolumeChanged();
        EncoderCombo.SelectionChanged += (_, _) => UpdateEncoderHint();

        DisplayCombo.DropDownOpened += (_, _) => RefreshDisplays();
        WindowCombo.DropDownOpened += (_, _) => RefreshWindows();
        RefreshWindowsButton.Click += (_, _) => RefreshWindows();
        PickRegionButton.Click += async (_, _) => await PickRecordingRegionAsync();

        ReplayCheck.Checked += async (_, _) => await StartReplayAsync();
        ReplayCheck.Unchecked += async (_, _) => await StopReplayAsync();
        ReplayLengthCombo.SelectionChanged += async (_, _) =>
        {
            if (_loading)
                return;
            _settings.ReplaySeconds = Selected(ReplayLengthCombo, 30);
            _settings.Save();
            if (_engine.IsReplayRunning)
                await StartReplayAsync();
        };
        SaveReplayButton.Click += async (_, _) => await SaveReplayAsync();

        BrowseVideoButton.Click += (_, _) => BrowseFolder(VideoFolderBox, path => _settings.VideoFolder = path);
        BrowseShotButton.Click += (_, _) => BrowseFolder(ShotFolderBox, path => _settings.ScreenshotFolder = path);
        OpenVideoButton.Click += (_, _) => OpenFolder(_settings.VideoFolder);
        OpenShotButton.Click += (_, _) => OpenFolder(_settings.ScreenshotFolder);

        foreach (TextBox box in new[] { HotkeyRecordBox, HotkeyPauseBox, HotkeyReplayBox, HotkeyShotBox, HotkeyOverlayBox, HotkeyMicBox })
        {
            box.PreviewKeyDown += OnHotkeyBoxKeyDown;
            // Release the global hotkeys while typing a new one, or pressing it would trigger the action instead.
            box.GotKeyboardFocus += (_, _) => _hotkeys?.Dispose();
            box.LostKeyboardFocus += (_, _) => RegisterHotkeys();
        }

        var pages = new (RadioButton Nav, FrameworkElement Page)[]
        {
            (NavCapture, PageCapture), (NavVideo, PageVideo), (NavAudio, PageAudio), (NavWebcam, PageWebcam),
            (NavReplay, PageReplay), (NavGeneral, PageGeneral), (NavHotkeys, PageHotkeys),
        };
        foreach (var (nav, page) in pages)
        {
            nav.Checked += (_, _) =>
            {
                foreach (var (_, other) in pages)
                    other.Visibility = other == page ? Visibility.Visible : Visibility.Collapsed;
                PageScroller.ScrollToTop();
                page.Opacity = 0;
                page.BeginAnimation(OpacityProperty, new System.Windows.Media.Animation.DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
            };
        }
        NavCapture.IsChecked = true;
        OpenOverlayButton.Click += (_, _) => ToggleOverlay();

        RecordButton.Click += async (_, _) => await ToggleRecordingAsync();
        PauseButton.Click += (_, _) => TogglePause();
        ScreenshotButton.Click += async (_, _) => await TakeScreenshotAsync();
        WindowShotButton.Click += async (_, _) => await TakeWindowScreenshotAsync();
    }

    // =====================================================================
    // Settings
    // =====================================================================

    private void OnSettingChanged()
    {
        if (_loading)
            return;
        SaveControlsToSettings();
        ApplyHideFromCapture();
        if (_engine.IsReplayRunning && !_engine.IsRecording)
        {
            _replayRestartTimer.Stop();
            _replayRestartTimer.Start();
        }
        UpdateUi();
    }

    private void OnVolumeChanged()
    {
        UpdateVolumeLabels();
        if (_loading)
            return;
        _settings.SystemVolume = (int)SystemVolumeSlider.Value;
        _settings.MicrophoneVolume = (int)MicVolumeSlider.Value;
        _settings.Save();
        // Volume applies live, even mid-recording.
        if (_engine.Pipeline?.SystemAudio is { } sys)
            sys.Gain = _settings.SystemVolume / 100f;
        ApplyMicGain();
    }

    private void UpdateVolumeLabels()
    {
        SystemVolumeText.Text = $"{(int)SystemVolumeSlider.Value}%";
        MicVolumeText.Text = $"{(int)MicVolumeSlider.Value}%";
    }

    private void SaveControlsToSettings()
    {
        AppSettings s = _settings;
        s.Source = SourceWindow.IsChecked == true ? SourceKind.Window : SourceRegion.IsChecked == true ? SourceKind.Region : SourceKind.Display;
        if (DisplayCombo.SelectedItem is DisplayInfo d)
            s.DisplayDevice = d.DeviceName;
        s.ShowCursor = ShowCursorCheck.IsChecked == true;
        s.HighlightClicks = ClicksCheck.IsChecked == true;
        s.MaxHeight = Selected(ResolutionCombo, 0);
        s.Fps = Selected(FpsCombo, 60);
        s.Quality = Selected(QualityCombo, QualityPreset.High);
        s.SaveAsMp4 = Selected(FormatCombo, true);
        if (EncoderCombo.SelectedItem is EncoderInfo enc)
            s.EncoderId = enc.Id;
        s.SystemAudio = SystemAudioCheck.IsChecked == true;
        s.SystemAudioDevice = (SystemDeviceCombo.SelectedItem as DeviceItem)?.Id;
        s.Microphone = MicCheck.IsChecked == true;
        s.MicrophoneDevice = (MicDeviceCombo.SelectedItem as DeviceItem)?.Id;
        s.Webcam = WebcamCheck.IsChecked == true;
        if (WebcamCombo.SelectedItem is DeviceItem cam)
            s.WebcamDevice = cam.Id;
        s.WebcamCorner = Selected(WebcamCornerCombo, WebcamCorner.BottomRight);
        s.WebcamSizePercent = Selected(WebcamSizeCombo, 24);
        s.WebcamShape = Selected(WebcamShapeCombo, WebcamShape.Circle);
        s.WebcamMirror = WebcamMirrorCheck.IsChecked == true;
        s.CopyScreenshotToClipboard = ClipboardCheck.IsChecked == true;
        s.HideFromCapture = HideSelfCheck.IsChecked == true;
        s.CloseToTray = CloseToTrayCheck.IsChecked == true;
        if (s.StartWithWindows != (StartupCheck.IsChecked == true))
        {
            s.StartWithWindows = StartupCheck.IsChecked == true;
            StartupRegistration.Apply(s.StartWithWindows);
        }
        s.Save();
    }

    private void UpdateSourcePanels()
    {
        DisplayCombo.Visibility = SourceDisplay.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        WindowPanel.Visibility = SourceWindow.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        RegionPanel.Visibility = SourceRegion.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateRegionText()
    {
        RegionText.Text = _settings.RegionWidth > 0
            ? $"{_settings.RegionWidth} × {_settings.RegionHeight} at ({_settings.RegionX}, {_settings.RegionY})"
            : "No area selected yet";
    }

    private void UpdateEncoderHint()
    {
        if (EncoderCombo.SelectedItem is not EncoderInfo enc)
            return;
        EncoderHint.ClearValue(TextBlock.ForegroundProperty);
        EncoderHint.Text = enc.Vendor switch
        {
            "nvidia" => "Encoding on your NVIDIA GPU (NVENC): high resolution and high frame rates with very little CPU load.",
            "amd" => "Encoding on your AMD GPU (AMF).",
            "intel" => "Encoding on Intel Quick Sync.",
            _ => _encoders.Any(e => e.IsHardware)
                ? "CPU encoding: very good quality but heavy. GPU encoding is usually the better choice."
                : "No GPU encoder was found, so encoding runs on the CPU. For smooth recording, try 1080p at 30–60 fps.",
        };
        if (enc.Codec != "h264")
            EncoderHint.Text += " HEVC/AV1 make smaller files, but older editors and phones may not open them.";
    }

    private void ApplyHideFromCapture()
    {
        IntPtr hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero)
            Win32.SetWindowDisplayAffinity(hwnd, _settings.HideFromCapture ? Win32.WDA_EXCLUDEFROMCAPTURE : Win32.WDA_NONE);
    }

    private void BrowseFolder(TextBox box, Action<string> set)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { InitialDirectory = Directory.Exists(box.Text) ? box.Text : null };
        if (dialog.ShowDialog(this) == true)
        {
            box.Text = dialog.FolderName;
            set(dialog.FolderName);
            _settings.Save();
        }
    }

    private static void OpenFolder(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"Open folder failed: {ex.Message}");
        }
    }

    // =====================================================================
    // Hotkeys
    // =====================================================================

    private void RegisterHotkeys()
    {
        if (_hotkeys == null)
            return;
        _hotkeys.Dispose();
        _hotkeys = new HotkeyManager(this);
        var failed = new List<string>();
        void Reg(int id, string text, Action action, string name)
        {
            if (!_hotkeys.Register(id, Hotkey.Parse(text), action))
                failed.Add($"{name} ({text})");
        }

        Reg(HotkeyRecordId, _settings.HotkeyRecord, () => _ = ToggleRecordingAsync(), "record");
        Reg(HotkeyPauseId, _settings.HotkeyPause, TogglePause, "pause");
        Reg(HotkeyReplayId, _settings.HotkeySaveReplay, () => _ = SaveReplayAsync(), "save replay");
        Reg(HotkeyShotId, _settings.HotkeyScreenshot, () => _ = TakeScreenshotAsync(), "screenshot");
        Reg(HotkeyOverlayId, _settings.HotkeyOverlay, ToggleOverlay, "overlay");
        Reg(HotkeyMicId, _settings.HotkeyMicMute, ToggleMicMute, "mute mic");
        OverlayHint.Text = string.IsNullOrEmpty(_settings.HotkeyOverlay) ? "" : $"{_settings.HotkeyOverlay} from anywhere";

        if (failed.Count > 0)
        {
            HotkeyHint.Text = "Another app is already using: " + string.Join(", ", failed) + ". Pick a different combination.";
            HotkeyHint.Foreground = Brushes.IndianRed;
        }
        else
        {
            HotkeyHint.Text = "Click a box and press the new key combination. Backspace clears it.";
            HotkeyHint.ClearValue(TextBlock.ForegroundProperty);
        }
    }

    private void OnHotkeyBoxKeyDown(object sender, KeyEventArgs e)
    {
        var box = (TextBox)sender;
        e.Handled = true;
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Tab)
        {
            e.Handled = false;
            return;
        }
        string text;
        if (key is Key.Back or Key.Delete or Key.Escape)
        {
            text = "";
        }
        else
        {
            Hotkey? hotkey = Hotkey.FromKeyEvent(e);
            if (hotkey == null)
                return;
            text = hotkey.ToString();
        }
        box.Text = text;
        if (box == HotkeyRecordBox) _settings.HotkeyRecord = text;
        else if (box == HotkeyPauseBox) _settings.HotkeyPause = text;
        else if (box == HotkeyReplayBox) _settings.HotkeySaveReplay = text;
        else if (box == HotkeyShotBox) _settings.HotkeyScreenshot = text;
        else if (box == HotkeyOverlayBox) _settings.HotkeyOverlay = text;
        else if (box == HotkeyMicBox) _settings.HotkeyMicMute = text;
        _settings.Save();
    }

    // =====================================================================
    // Building the capture config
    // =====================================================================

    private PipelineConfig BuildConfig()
    {
        CaptureTarget target;
        if (SourceWindow.IsChecked == true)
        {
            if (WindowCombo.SelectedItem is not WindowInfo w)
                throw new InvalidOperationException("Pick a window to record first.");
            if (!Win32.IsWindow(w.Handle))
            {
                RefreshWindows();
                throw new InvalidOperationException("That window has been closed. Pick another one.");
            }
            if (Win32.IsIconic(w.Handle))
                throw new InvalidOperationException("That window is minimised. Restore it first.");
            IntPtr monitor = Win32.MonitorFromWindow(w.Handle, Win32.MONITOR_DEFAULTTONEAREST);
            DisplayInfo? display = ScreenInfo.GetDisplays().FirstOrDefault(d => d.Handle == monitor);
            target = new CaptureTarget(SourceKind.Window, monitor, display?.Bounds ?? default, w.Handle, default, w.Title);
        }
        else if (SourceRegion.IsChecked == true)
        {
            DisplayInfo? display = ScreenInfo.GetDisplays().FirstOrDefault(d => d.DeviceName == _settings.RegionDisplayDevice);
            var region = new RECT(_settings.RegionX, _settings.RegionY,
                _settings.RegionX + _settings.RegionWidth, _settings.RegionY + _settings.RegionHeight);
            if (display == null || _settings.RegionWidth < 16 || _settings.RegionHeight < 16 ||
                region.Left < display.Bounds.Left || region.Top < display.Bounds.Top ||
                region.Right > display.Bounds.Right || region.Bottom > display.Bounds.Bottom)
                throw new InvalidOperationException("Select the area to record first (the screen layout may have changed).");
            target = new CaptureTarget(SourceKind.Region, display.Handle, display.Bounds, IntPtr.Zero, region,
                $"area {region.Width}×{region.Height}");
        }
        else
        {
            if (DisplayCombo.SelectedItem is not DisplayInfo d)
                throw new InvalidOperationException("No screen found to record.");
            target = new CaptureTarget(SourceKind.Display, d.Handle, d.Bounds, IntPtr.Zero, d.Bounds, d.Label);
        }

        EncoderInfo encoder = EncoderCombo.SelectedItem as EncoderInfo ?? EncoderCatalog.PickDefault(_encoders);

        WebcamOptions? webcam = null;
        if (WebcamCheck.IsChecked == true && WebcamCombo.SelectedItem is DeviceItem { Id: { } camId })
            webcam = new WebcamOptions(camId, _settings.WebcamCorner, _settings.WebcamSizePercent / 100.0, _settings.WebcamShape, _settings.WebcamMirror);

        AudioOptions? system = SystemAudioCheck.IsChecked == true
            ? new AudioOptions((SystemDeviceCombo.SelectedItem as DeviceItem)?.Id, _settings.SystemVolume / 100f)
            : null;
        AudioOptions? mic = MicCheck.IsChecked == true
            ? new AudioOptions((MicDeviceCombo.SelectedItem as DeviceItem)?.Id, _micMuted ? 0f : _settings.MicrophoneVolume / 100f)
            : null;

        return new PipelineConfig(target, _settings.Fps, _settings.MaxHeight, _settings.ShowCursor, _settings.HighlightClicks,
            webcam, system, mic, new EncoderOptions(encoder, _settings.Quality));
    }

    // =====================================================================
    // Actions
    // =====================================================================

    private async Task ToggleRecordingAsync()
    {
        if (_engine.IsBusy)
            return;
        try
        {
            if (_engine.IsRecording)
            {
                string? path = await _engine.StopRecordingAsync();
                if (path != null)
                {
                    ShowNotice($"Saved {path}", false);
                    Toast.Show("Recording saved", Path.GetFileName(path), path);
                }
            }
            else
            {
                PipelineConfig cfg = BuildConfig();
                ShowNotice("Starting…", false);
                await _engine.StartRecordingAsync(cfg, _settings.VideoFolder, _settings.SaveAsMp4);
                ShowNotice("", false);
            }
        }
        catch (Exception ex)
        {
            Log.Error("Record toggle failed", ex);
            ShowNotice(ex.Message, true);
            Toast.Show("Couldn't record", ex.Message, isError: true);
        }
        UpdateUi();
    }

    private void TogglePause()
    {
        if (!_engine.IsRecording)
            return;
        _engine.TogglePause();
        UpdateUi();
    }

    private async Task StartReplayAsync()
    {
        if (_loading && !_settings.ReplayEnabled)
            return;
        _settings.ReplayEnabled = true;
        _settings.Save();
        if (_engine.FfmpegPath == null || _encoders.Count == 0)
            return; // Starts automatically once encoders are known.
        try
        {
            await _engine.StartReplayAsync(BuildConfig(), Selected(ReplayLengthCombo, 30));
            ShowNotice($"Replay buffer on: {_settings.HotkeySaveReplay} saves the last {FormatSeconds(_settings.ReplaySeconds)}.", false);
        }
        catch (Exception ex)
        {
            Log.Error("Replay start failed", ex);
            ShowNotice($"Replay buffer couldn't start: {ex.Message}", true);
            _loading = true;
            ReplayCheck.IsChecked = false;
            _loading = false;
            _settings.ReplayEnabled = false;
            _settings.Save();
        }
        UpdateUi();
    }

    private async Task StopReplayAsync()
    {
        if (_loading)
            return;
        _settings.ReplayEnabled = false;
        _settings.Save();
        try
        {
            await _engine.StopReplayAsync();
        }
        catch (Exception ex)
        {
            Log.Error("Replay stop failed", ex);
        }
        UpdateUi();
    }

    private async Task ApplySettingsToReplayAsync()
    {
        if (!_engine.IsReplayRunning || _engine.IsRecording)
            return;
        try
        {
            await _engine.StartReplayAsync(BuildConfig(), _settings.ReplaySeconds);
        }
        catch (Exception ex)
        {
            ShowNotice($"Replay buffer couldn't apply the new settings: {ex.Message}", true);
        }
    }

    private async Task SaveReplayAsync()
    {
        if (!_engine.IsReplayRunning)
        {
            Toast.Show("Replay buffer is off", "Turn on \"Always keep the last…\" in Recshot first.", isError: true);
            return;
        }
        try
        {
            ShowNotice("Saving replay…", false);
            string path = await _engine.SaveReplayAsync(_settings.VideoFolder);
            ShowNotice($"Saved {path}", false);
            Toast.Show("Replay saved", $"Last {FormatSeconds(_settings.ReplaySeconds)} · {Path.GetFileName(path)}", path);
        }
        catch (Exception ex)
        {
            Log.Error("Replay save failed", ex);
            ShowNotice(ex.Message, true);
            Toast.Show("Couldn't save replay", ex.Message, isError: true);
        }
    }

    private async Task PickRecordingRegionAsync()
    {
        RegionPicker.Selection? selection = await RegionPicker.PickAsync("Drag over the area to record   ·   Click for a whole screen   ·   Esc to cancel");
        if (selection == null)
            return;
        RECT r = selection.Rect;
        // Video needs even dimensions.
        _settings.RegionX = r.Left;
        _settings.RegionY = r.Top;
        _settings.RegionWidth = Math.Max(16, r.Width & ~1);
        _settings.RegionHeight = Math.Max(16, r.Height & ~1);
        _settings.RegionDisplayDevice = selection.Display.DeviceName;
        UpdateRegionText();
        SourceRegion.IsChecked = true;
        OnSettingChanged();
    }

    private async Task TakeScreenshotAsync()
    {
        try
        {
            RegionPicker.Selection? selection = await RegionPicker.PickAsync("Drag to capture an area   ·   Click to capture the whole screen   ·   Esc to cancel");
            if (selection == null || selection.Rect.Width < 1 || selection.Rect.Height < 1)
                return;
            await SaveScreenshotAsync(selection.Crop());
        }
        catch (Exception ex)
        {
            Log.Error("Screenshot failed", ex);
            Toast.Show("Screenshot failed", ex.Message, isError: true);
        }
    }

    private async Task TakeWindowScreenshotAsync()
    {
        try
        {
            if (WindowCombo.SelectedItem is not WindowInfo w)
            {
                SourceWindow.IsChecked = true;
                ShowNotice("Pick a window in the list under \"One window\", then press Window shot.", true);
                return;
            }
            if (!Win32.IsWindow(w.Handle))
            {
                RefreshWindows();
                throw new InvalidOperationException("That window has been closed.");
            }
            BitmapSource image = await ScreenGrabber.CaptureWindowAsync(w.Handle);
            await SaveScreenshotAsync(image);
        }
        catch (Exception ex)
        {
            Log.Error("Window screenshot failed", ex);
            Toast.Show("Screenshot failed", ex.Message, isError: true);
        }
    }

    private async Task SaveScreenshotAsync(BitmapSource image)
    {
        string path = await ScreenGrabber.SavePngAsync(image, _settings.ScreenshotFolder);
        bool copied = false;
        if (_settings.CopyScreenshotToClipboard)
        {
            // The clipboard can be briefly locked by other apps.
            for (int attempt = 0; attempt < 5 && !copied; attempt++)
            {
                try
                {
                    Clipboard.SetImage(image);
                    copied = true;
                }
                catch
                {
                    await Task.Delay(60);
                }
            }
        }
        string details = $"{image.PixelWidth} × {image.PixelHeight}{(copied ? " · copied to clipboard" : "")}";
        ShowNotice($"Screenshot saved: {path}", false);
        Toast.Show("Screenshot saved", details, path);
    }

    // =====================================================================
    // UI state
    // =====================================================================

    private void ShowNotice(string message, bool isError)
    {
        _notice = string.IsNullOrWhiteSpace(message) ? null : message;
        _noticeIsError = isError;
        _noticeUntil = DateTime.Now.AddSeconds(isError ? 12 : 6);
        UpdateUi();
    }

    private void Tick()
    {
        SystemMeter.Value = _engine.Pipeline?.SystemAudio?.Level ?? 0;
        MicMeter.Value = _engine.Pipeline?.Microphone?.Level ?? 0;
        if (_engine.IsRecording)
        {
            UpdateTray();
            UpdateHud();
            TimerText.Text = _engine.RecordingElapsed.ToString(@"hh\:mm\:ss");
            bool paused = _engine.IsPaused;
            Title = $"{(paused ? "❚❚ Paused" : "● REC")} {TimerText.Text} · Recshot";
            // Blink the dot while recording, hold it while paused.
            RecordDot.Opacity = paused || DateTime.Now.Millisecond < 600 ? 1 : 0.25;
        }
        if (_notice != null && DateTime.Now > _noticeUntil)
        {
            _notice = null;
            UpdateUi();
        }
    }

    private void UpdateUi()
    {
        UpdateTray();
        UpdateHud();
        _overlay?.Refresh();
        bool recording = _engine.IsRecording;
        bool busy = _engine.IsBusy;
        bool ready = _engine.FfmpegPath != null && _encoders.Count > 0;

        RecordLabel.Text = recording ? "Stop recording" : busy ? "Please wait…" : "Start recording";
        RecordDot.Fill = recording ? Brushes.White : new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
        RecordButton.Background = recording ? new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26)) : null;
        if (!recording)
            RecordButton.ClearValue(BackgroundProperty);
        RecordButton.Foreground = recording ? Brushes.White : null;
        if (!recording)
            RecordButton.ClearValue(ForegroundProperty);
        RecordButton.IsEnabled = ready && !busy;
        PauseButton.IsEnabled = recording && !busy;
        PauseButton.Content = _engine.IsPaused ? "Resume" : "Pause";
        SaveReplayButton.IsEnabled = _engine.IsReplayRunning && !busy;
        ReplayCheck.IsEnabled = ready && !busy;
        ReplayLengthCombo.IsEnabled = !busy;
        foreach (Control c in _lockedWhileRecording)
            c.IsEnabled = !recording && !busy;
        if (WebcamCheck.Content as string == "No webcam found")
            WebcamCheck.IsEnabled = false;

        if (!recording)
        {
            TimerText.Text = "00:00:00";
            TimerText.Opacity = 0.55;
            Title = "Recshot";
            RecordDot.Opacity = 1;
        }
        else
        {
            TimerText.Opacity = 1;
        }

        if (_notice != null)
        {
            StatusText.Text = _notice;
            StatusText.Foreground = _noticeIsError ? Brushes.IndianRed : null;
            if (!_noticeIsError)
                StatusText.ClearValue(TextBlock.ForegroundProperty);
            return;
        }
        StatusText.ClearValue(TextBlock.ForegroundProperty);

        string status;
        if (_engine.FfmpegPath == null && !_loading)
            status = "FFmpeg is missing, so recording is unavailable. Screenshots still work.";
        else if (!ready)
            status = "Getting ready…";
        else if (recording)
            status = $"{(_engine.IsPaused ? "Paused" : "Recording")} · {_engine.ActiveOutputSize} · {_settings.HotkeyRecord} to stop";
        else
            status = $"Ready · {_settings.HotkeyRecord} to record · {_settings.HotkeyScreenshot} for a screenshot";
        if (_engine.IsReplayRunning)
            status += $" · Replay buffer on ({FormatSeconds(_settings.ReplaySeconds)}, {_settings.HotkeySaveReplay} saves it)";
        StatusText.Text = status;
    }

    private void UpdateTray()
    {
        if (_tray == null)
            return;
        string tip = _engine.IsRecording
            ? $"Recshot · {(_engine.IsPaused ? "paused" : "recording")} {_engine.RecordingElapsed:hh\\:mm\\:ss}"
            : _engine.IsReplayRunning ? $"Recshot · replay buffer on ({_settings.HotkeySaveReplay} saves)" : "Recshot · ready";
        _tray.Update(_engine.IsRecording, _engine.IsPaused, _engine.IsReplayRunning, tip);
    }

    // =====================================================================
    // Overlay, HUD, mic mute
    // =====================================================================

    private void ToggleOverlay()
    {
        if (_overlay != null)
        {
            _overlay.CloseAnimated();
            return;
        }
        try
        {
            Win32.GetCursorPos(out POINT cursor);
            DisplayInfo display = ScreenInfo.DisplayContaining(cursor.X, cursor.Y) ?? ScreenInfo.GetDisplays().First(d => d.IsPrimary);
            _overlay = new OverlayWindow(this, display);
            _overlay.Closed += (_, _) => _overlay = null;
            _overlay.Show();
        }
        catch (Exception ex)
        {
            Log.Error("Overlay failed", ex);
            _overlay = null;
        }
    }

    private void UpdateHud()
    {
        if (_engine.IsRecording)
        {
            _hud ??= new RecordingHud();
            if (!_hud.IsVisible)
                _hud.Show();
            _hud.Update(_engine.RecordingElapsed, _engine.IsPaused, MicCheck.IsChecked == true, _micMuted);
        }
        else if (_hud != null)
        {
            _hud.Close();
            _hud = null;
        }
    }

    public void ToggleMicMute()
    {
        _micMuted = !_micMuted;
        ApplyMicGain();
        Toast.Show(_micMuted ? "Microphone muted" : "Microphone on",
            _micMuted ? $"{_settings.HotkeyMicMute} to unmute" : "Your voice is being recorded.");
        UpdateUi();
    }

    private void ApplyMicGain()
    {
        if (_engine.Pipeline?.Microphone is { } mic)
            mic.Gain = _micMuted ? 0f : _settings.MicrophoneVolume / 100f;
    }

    // IOverlayHost
    bool IOverlayHost.IsRecording => _engine.IsRecording;
    bool IOverlayHost.IsPaused => _engine.IsPaused;
    bool IOverlayHost.IsReplayRunning => _engine.IsReplayRunning;
    bool IOverlayHost.MicEnabled => MicCheck.IsChecked == true;
    bool IOverlayHost.MicMuted => _micMuted;
    bool IOverlayHost.SystemEnabled => SystemAudioCheck.IsChecked == true;
    int IOverlayHost.SystemVolume { get => (int)SystemVolumeSlider.Value; set => SystemVolumeSlider.Value = value; }
    int IOverlayHost.MicVolume { get => (int)MicVolumeSlider.Value; set => MicVolumeSlider.Value = value; }
    float IOverlayHost.SystemLevel => _engine.Pipeline?.SystemAudio?.Level ?? 0;
    float IOverlayHost.MicLevel => _engine.Pipeline?.Microphone?.Level ?? 0;
    TimeSpan IOverlayHost.Elapsed => _engine.RecordingElapsed;
    AppSettings IOverlayHost.Settings => _settings;
    string? IOverlayHost.FfmpegPath => _engine.FfmpegPath;
    void IOverlayHost.ToggleRecord() => _ = ToggleRecordingAsync();
    void IOverlayHost.TogglePauseRecording() => TogglePause();
    void IOverlayHost.SaveReplay() => _ = SaveReplayAsync();
    void IOverlayHost.ToggleReplay() => ReplayCheck.IsChecked = ReplayCheck.IsChecked != true;
    void IOverlayHost.Screenshot() => _ = TakeScreenshotAsync();
    void IOverlayHost.OpenSettings() => ShowFromTray();

    // =====================================================================
    // Tray
    // =====================================================================

    public void ShowFromTray()
    {
        Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
        Topmost = true;  // bring it in front even if another app is focused
        Topmost = false;
        Focus();
    }

    private void HideToTray()
    {
        Hide();
        if (!_settings.TrayHintShown)
        {
            _settings.TrayHintShown = true;
            _settings.Save();
            _tray?.ShowBalloon("Recshot is still running",
                "Hotkeys and the replay buffer keep working. Click the tray icon to reopen, or right-click → Quit to exit.");
        }
    }

    private void QuitFromTray()
    {
        _quitRequested = true;
        ShowFromTray();
        Close();
    }

    private static string FormatSeconds(int seconds) => seconds < 60 ? $"{seconds} s" : $"{seconds / 60} min";

    // =====================================================================
    // Shutdown
    // =====================================================================

    protected override async void OnClosing(CancelEventArgs e)
    {
        if (_closeConfirmed)
        {
            base.OnClosing(e);
            return;
        }
        e.Cancel = true;

        if (_settings.CloseToTray && !_quitRequested)
        {
            HideToTray();
            return;
        }
        _quitRequested = false;

        if (_engine.IsRecording)
        {
            MessageBoxResult answer = MessageBox.Show(this, "A recording is in progress. Stop and save it, then quit?",
                "Recshot", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (answer != MessageBoxResult.Yes)
                return;
        }

        IsEnabled = false;
        StatusText.Text = "Saving and closing…";
        try
        {
            if (_engine.IsRecording)
            {
                string? path = await _engine.StopRecordingAsync();
                Log.Info($"Saved on exit: {path}");
            }
            await _engine.ShutdownAsync();
        }
        catch (Exception ex)
        {
            Log.Error("Shutdown", ex);
        }
        _uiTimer.Stop();
        _hotkeys?.Dispose();
        _tray?.Dispose();
        _hud?.Close();
        _overlay?.Close();
        _closeConfirmed = true;
        Close();
    }
}
