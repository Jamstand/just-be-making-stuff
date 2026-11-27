using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Recshot.Capture;
using Recshot.Core;
using Recshot.Native;

namespace Recshot.UI;

/// <summary>Everything the overlay needs from the app.</summary>
internal interface IOverlayHost
{
    bool IsRecording { get; }
    bool IsPaused { get; }
    bool IsReplayRunning { get; }
    bool MicEnabled { get; }
    bool SystemEnabled { get; }
    int SystemVolume { get; set; }
    int MicVolume { get; set; }
    float SystemLevel { get; }
    float MicLevel { get; }
    bool MicMuted { get; }
    TimeSpan Elapsed { get; }
    AppSettings Settings { get; }
    string? FfmpegPath { get; }
    void ToggleRecord();
    void TogglePauseRecording();
    void SaveReplay();
    void ToggleReplay();
    void Screenshot();
    void ToggleMicMute();
    void OpenSettings();
}

/// <summary>
/// Full-screen quick-actions overlay (Alt+R by default): blurred, dimmed snapshot of the screen,
/// a clock, big glass tiles and the latest captures — Apple TV look, Xbox Guide / NVIDIA overlay job.
/// </summary>
internal sealed class OverlayWindow : Window
{
    private static readonly Duration Fast = TimeSpan.FromMilliseconds(220);

    private readonly IOverlayHost _host;
    private readonly DisplayInfo _display;
    private readonly Grid _content;
    private readonly ScaleTransform _contentScale = new(0.94, 0.94);
    private readonly WrapPanel _tiles = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel _gallery = new() { Orientation = Orientation.Horizontal };
    private readonly TextBlock _clock;
    private readonly TextBlock _date;
    private readonly Border _statusChip;
    private readonly TextBlock _statusText;
    private readonly System.Windows.Threading.DispatcherTimer _timer;
    private bool _closing;
    private readonly System.Windows.Threading.DispatcherTimer _meterTimer;
    private ProgressBar _systemMeter = null!;
    private ProgressBar _micMeter = null!;

    public OverlayWindow(IOverlayHost host, DisplayInfo display)
    {
        _host = host;
        _display = display;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Left = display.Bounds.Left;
        Top = display.Bounds.Top;
        Width = Math.Max(1, display.Bounds.Width);
        Height = Math.Max(1, display.Bounds.Height);

        var root = new Grid();

        // Transparent over the live screen, like the Xbox Game Bar: a soft dark veil, everything behind keeps moving.
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        var veil = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        veil.GradientStops.Add(new GradientStop(Color.FromArgb(0x99, 0x05, 0x06, 0x09), 0));
        veil.GradientStops.Add(new GradientStop(Color.FromArgb(0x66, 0x05, 0x06, 0x09), 0.5));
        veil.GradientStops.Add(new GradientStop(Color.FromArgb(0xB3, 0x05, 0x06, 0x09), 1));
        root.Children.Add(new Border { Background = veil });

        // Foreground content, animated in.
        _content = new Grid { Margin = new Thickness(64, 48, 64, 40), RenderTransformOrigin = new Point(0.5, 0.45), RenderTransform = _contentScale, Opacity = 0 };
        _content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // --- Top bar: brand + status on the left, big clock on the right.
        var top = new Grid();
        var brand = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        brand.Children.Add(new TextBlock { Text = "Recshot", FontSize = 22, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        _statusText = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White };
        _statusChip = new Border
        {
            Margin = new Thickness(16, 0, 0, 0), Padding = new Thickness(12, 5, 12, 5), CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)), Child = _statusText, VerticalAlignment = VerticalAlignment.Center,
        };
        brand.Children.Add(_statusChip);
        top.Children.Add(brand);

        var clockStack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        _clock = new TextBlock { FontSize = 56, FontWeight = FontWeights.Light, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Right };
        _date = new TextBlock { FontSize = 15, Foreground = (Brush)FindResource("TextSecondary"), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, -4, 4, 0) };
        clockStack.Children.Add(_clock);
        clockStack.Children.Add(_date);
        top.Children.Add(clockStack);
        Grid.SetRow(top, 0);
        _content.Children.Add(top);

        // --- Tiles, centred.
        KeyboardNavigation.SetDirectionalNavigation(_tiles, KeyboardNavigationMode.Cycle);
        KeyboardNavigation.SetTabNavigation(_tiles, KeyboardNavigationMode.Cycle);
        var tilesHost = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        tilesHost.Children.Add(_tiles);
        tilesHost.Children.Add(BuildAudioWidget());
        Grid.SetRow(tilesHost, 1);
        _content.Children.Add(tilesHost);

        // --- Recent captures.
        var galleryHeader = new DockPanel { Margin = new Thickness(10, 0, 10, 6) };
        galleryHeader.Children.Add(new TextBlock { Text = "Recent captures", FontSize = 18, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White });
        var openFolder = new TextBlock
        {
            Text = "Open folder  ", FontSize = 13, Foreground = (Brush)FindResource("TextSecondary"), Cursor = Cursors.Hand,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            FontFamily = new FontFamily("Segoe UI, Segoe Fluent Icons, Segoe MDL2 Assets"),
        };
        openFolder.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            Launch("explorer.exe", $"\"{_host.Settings.VideoFolder}\"");
            CloseAnimated();
        };
        galleryHeader.Children.Add(openFolder);
        Grid.SetRow(galleryHeader, 2);
        _content.Children.Add(galleryHeader);

        var galleryScroll = new ScrollViewer
        {
            Content = _gallery, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            PanningMode = PanningMode.HorizontalOnly,
        };
        galleryScroll.PreviewMouseWheel += (_, e) =>
        {
            galleryScroll.ScrollToHorizontalOffset(galleryScroll.HorizontalOffset - e.Delta);
            e.Handled = true;
        };
        Grid.SetRow(galleryScroll, 3);
        _content.Children.Add(galleryScroll);

        root.Children.Add(_content);
        root.Children.Add(new TextBlock
        {
            Text = $"Esc or {_host.Settings.HotkeyOverlay} to close", FontSize = 12, Foreground = (Brush)FindResource("TextTertiary"),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 14),
        });
        Content = root;

        // Clicking empty space closes, like tapping outside a sheet.
        root.MouseLeftButtonUp += (_, e) =>
        {
            if (e.OriginalSource == root || e.OriginalSource is Border { Child: null })
                CloseAnimated();
        };

        _timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _timer.Tick += (_, _) => UpdateClockAndStatus();
        _meterTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        _meterTimer.Tick += (_, _) =>
        {
            _systemMeter.Value = _host.SystemLevel;
            _micMeter.Value = _host.MicMuted ? 0 : _host.MicLevel;
        };

        SourceInitialized += (_, _) =>
        {
            SnapToDisplay();
            Win32.SetWindowDisplayAffinity(new WindowInteropHelper(this).Handle, Win32.WDA_EXCLUDEFROMCAPTURE);
        };
        Loaded += (_, _) =>
        {
            SnapToDisplay();
            Refresh();
            AnimateIn();
            _ = LoadGalleryAsync();
            _timer.Start();
            _meterTimer.Start();
            Activate();
        };
        Closed += (_, _) =>
        {
            _timer.Stop();
            _meterTimer.Stop();
        };
    }

    private void SnapToDisplay()
    {
        IntPtr hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero)
            return;
        for (int i = 0; i < 2; i++)
            Win32.SetWindowPos(hwnd, Win32.HWND_TOPMOST, _display.Bounds.Left, _display.Bounds.Top,
                _display.Bounds.Width, _display.Bounds.Height, 0);
    }

    // ------------------------------------------------------------------ tiles

    /// <summary>Rebuilds the tiles from the current state (cheap; called after every action).</summary>
    public void Refresh()
    {
        if (_closing)
            return;
        AppSettings s = _host.Settings;
        IInputElement? focused = Keyboard.FocusedElement;
        int focusedIndex = focused is Button b ? _tiles.Children.IndexOf(b) : 0;
        _tiles.Children.Clear();

        bool rec = _host.IsRecording;
        AddTile(rec ? "" : "", rec ? "Stop" : "Record", rec ? _host.Elapsed.ToString(@"hh\:mm\:ss") : s.HotkeyRecord,
            closeFirst: !rec, _host.ToggleRecord, iconBrush: rec ? null : (Brush)FindResource("RecordRed"));
        AddTile(_host.IsPaused ? "" : "", _host.IsPaused ? "Resume" : "Pause", s.HotkeyPause,
            closeFirst: false, _host.TogglePauseRecording, enabled: rec);
        AddTile("", "Save replay", _host.IsReplayRunning ? $"Last {FormatSeconds(s.ReplaySeconds)} · {s.HotkeySaveReplay}" : "Replay is off",
            closeFirst: true, _host.SaveReplay, enabled: _host.IsReplayRunning);
        AddTile("", "Instant replay", _host.IsReplayRunning ? "On" : "Off", closeFirst: false, _host.ToggleReplay, isOn: _host.IsReplayRunning);
        AddTile("", "Screenshot", s.HotkeyScreenshot, closeFirst: true, _host.Screenshot);
        if (_host.MicEnabled)
            AddTile(_host.MicMuted ? "" : "", "Microphone", _host.MicMuted ? "Muted" : $"On · {s.HotkeyMicMute}",
                closeFirst: false, _host.ToggleMicMute, isOn: !_host.MicMuted, iconBrush: _host.MicMuted ? (Brush)FindResource("RecordRed") : null);
        AddTile("", "Settings", "All options", closeFirst: true, _host.OpenSettings);

        if (_tiles.Children.Count > 0)
        {
            var target = (Button)_tiles.Children[Math.Clamp(focusedIndex, 0, _tiles.Children.Count - 1)];
            if (!target.IsEnabled)
                target = _tiles.Children.OfType<Button>().First(t => t.IsEnabled);
            Dispatcher.BeginInvoke(() => target.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        }
        UpdateClockAndStatus();
    }

    private void AddTile(string glyph, string title, string subtitle, bool closeFirst, Action action,
        bool enabled = true, bool? isOn = null, Brush? iconBrush = null)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(new TextBlock
        {
            Text = glyph, FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 34,
            Foreground = iconBrush ?? Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 12),
        });
        stack.Children.Add(new TextBlock { Text = title, FontSize = 16, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });

        UIElement sub;
        if (isOn != null)
        {
            // On/off pill, white when on, like tvOS toggles.
            sub = new Border
            {
                Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(10, 2, 10, 3), CornerRadius = new CornerRadius(9),
                HorizontalAlignment = HorizontalAlignment.Center,
                Background = isOn.Value ? Brushes.White : new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
                Child = new TextBlock
                {
                    Text = subtitle, FontSize = 11, FontWeight = FontWeights.Bold,
                    Foreground = isOn.Value ? new SolidColorBrush(Color.FromRgb(0x0B, 0x0C, 0x10)) : Brushes.White,
                },
            };
        }
        else
        {
            sub = new TextBlock
            {
                Text = subtitle, FontSize = 12, Foreground = (Brush)FindResource("TextSecondary"),
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 5, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis,
            };
        }
        stack.Children.Add(sub);

        var tile = new Button { Style = (Style)FindResource("OverlayTile"), Content = stack, IsEnabled = enabled };
        tile.Click += (_, _) =>
        {
            if (closeFirst)
            {
                CloseAnimated(action);
            }
            else
            {
                action();
                // The host updates state asynchronously; refresh shortly after.
                Dispatcher.BeginInvoke(Refresh, System.Windows.Threading.DispatcherPriority.Background);
            }
        };
        _tiles.Children.Add(tile);
    }

    /// <summary>Game Bar–style audio widget: live levels and volume for computer sound and mic.</summary>
    private UIElement BuildAudioWidget()
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = "Audio", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, Margin = new Thickness(0, 0, 0, 10) });
        panel.Children.Add(AudioRow("\uE767", "Computer sound", _host.SystemEnabled, _host.SystemVolume, v => _host.SystemVolume = v, out _systemMeter));
        panel.Children.Add(AudioRow("\uE720", "Microphone", _host.MicEnabled, _host.MicVolume, v => _host.MicVolume = v, out _micMeter));
        return new Border
        {
            Width = 420, Margin = new Thickness(0, 28, 0, 0), Padding = new Thickness(20, 16, 20, 14), HorizontalAlignment = HorizontalAlignment.Center,
            CornerRadius = new CornerRadius(20), Background = new SolidColorBrush(Color.FromArgb(0xB0, 0x14, 0x15, 0x1A)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(1),
            Child = panel,
        };
    }

    private static UIElement AudioRow(string glyph, string name, bool enabled, int volume, Action<int> set, out ProgressBar meter)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 8), Opacity = enabled ? 1 : 0.4, IsEnabled = enabled };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition());
        var icon = new TextBlock { Text = glyph, FontFamily = (FontFamily)Application.Current.FindResource("IconFont"), FontSize = 16, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock { Text = enabled ? name : $"{name} (off)", FontSize = 12, Foreground = (Brush)Application.Current.FindResource("TextSecondary") };
        var slider = new Slider { Minimum = 0, Maximum = 200, Value = volume, TickFrequency = 5, IsSnapToTickEnabled = true, VerticalAlignment = VerticalAlignment.Center };
        var value = new TextBlock { Text = $"{volume}%", FontSize = 12, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, e) =>
        {
            value.Text = $"{(int)e.NewValue}%";
            set((int)e.NewValue);
        };
        meter = new ProgressBar { Height = 3, Minimum = 0, Maximum = 1, Margin = new Thickness(0, 2, 0, 0), Foreground = Brushes.White, Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(0) };
        Grid.SetRowSpan(icon, 2);
        Grid.SetColumn(label, 1);
        Grid.SetColumn(slider, 1);
        Grid.SetRow(slider, 1);
        Grid.SetColumn(value, 2);
        Grid.SetRow(value, 1);
        var sliderAndMeter = new StackPanel();
        grid.Children.Add(icon);
        grid.Children.Add(label);
        grid.Children.Remove(slider);
        sliderAndMeter.Children.Add(slider);
        sliderAndMeter.Children.Add(meter);
        Grid.SetColumn(sliderAndMeter, 1);
        Grid.SetRow(sliderAndMeter, 1);
        grid.Children.Add(sliderAndMeter);
        grid.Children.Add(value);
        return grid;
    }

    private void UpdateClockAndStatus()
    {
        DateTime now = DateTime.Now;
        _clock.Text = now.ToString("t");
        _date.Text = now.ToString("dddd d MMMM");
        if (_host.IsRecording)
        {
            _statusText.Text = $"{(_host.IsPaused ? "❚❚  Paused" : "●  Recording")}  {_host.Elapsed:hh\\:mm\\:ss}";
            _statusChip.Background = (Brush)FindResource(_host.IsPaused ? "PausedAmber" : "RecordRed");
            _statusText.Foreground = _host.IsPaused ? Brushes.Black : Brushes.White;
        }
        else
        {
            _statusText.Text = _host.IsReplayRunning ? $"Instant replay on · {FormatSeconds(_host.Settings.ReplaySeconds)}" : "Ready";
            _statusChip.Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF));
            _statusText.Foreground = Brushes.White;
        }
    }

    // ------------------------------------------------------------------ gallery

    private async Task LoadGalleryAsync()
    {
        _gallery.Children.Clear();
        string? exclude = null;
        List<Gallery.Item> items = await Task.Run(() => Gallery.Recent(_host.Settings.VideoFolder, _host.Settings.ScreenshotFolder, 12, exclude));
        if (items.Count == 0)
        {
            _gallery.Children.Add(new TextBlock
            {
                Text = "Nothing captured yet. Your recordings, replays and screenshots will show up here.",
                FontSize = 14, Foreground = (Brush)FindResource("TextSecondary"), Margin = new Thickness(10, 8, 0, 18),
            });
            return;
        }

        int index = 0;
        foreach (Gallery.Item item in items)
        {
            if (_host.IsRecording && item.Path.EndsWith(".mkv", StringComparison.OrdinalIgnoreCase) && DateTime.Now - item.When < TimeSpan.FromSeconds(10))
                continue; // the file being recorded right now

            var picture = new Border
            {
                Height = 112, CornerRadius = new CornerRadius(14),
                Background = new SolidColorBrush(Color.FromArgb(0x22, 0xFF, 0xFF, 0xFF)),
                ClipToBounds = true,
            };
            var pictureGrid = new Grid();
            picture.Child = pictureGrid;
            if (item.IsVideo)
            {
                pictureGrid.Children.Add(new Border
                {
                    Width = 38, Height = 38, CornerRadius = new CornerRadius(19),
                    Background = new SolidColorBrush(Color.FromArgb(0xA0, 0, 0, 0)),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    Child = new TextBlock
                    {
                        Text = "", FontFamily = (FontFamily)FindResource("IconFont"), FontSize = 16, Foreground = Brushes.White,
                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 0, 0),
                    },
                });
            }

            var card = new StackPanel();
            card.Children.Add(picture);
            card.Children.Add(new TextBlock
            {
                Text = Gallery.Describe(item), FontSize = 12, Foreground = (Brush)FindResource("TextSecondary"),
                Margin = new Thickness(2, 8, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis,
            });

            var button = new Button
            {
                Style = (Style)FindResource("ThumbButton"), Content = card, ToolTip = System.IO.Path.GetFileName(item.Path),
                Padding = new Thickness(0), Opacity = 0,
            };
            button.Click += (_, _) =>
            {
                Launch(item.Path, null);
                CloseAnimated();
            };
            button.MouseRightButtonUp += (_, e) =>
            {
                e.Handled = true;
                Launch("explorer.exe", $"/select,\"{item.Path}\"");
                CloseAnimated();
            };
            _gallery.Children.Add(button);
            button.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Fast) { BeginTime = TimeSpan.FromMilliseconds(40 * index++) });

            BitmapSource? thumb = await Gallery.ThumbnailAsync(item, _host.FfmpegPath);
            if (thumb != null)
            {
                var brush = new ImageBrush(thumb) { Stretch = Stretch.UniformToFill };
                brush.Freeze();
                pictureGrid.Children.Insert(0, new Border { CornerRadius = new CornerRadius(14), Background = brush });
            }
        }
    }

    // ------------------------------------------------------------------ open / close

    private void AnimateIn()
    {
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        _content.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Fast));
        _contentScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.94, 1, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
        _contentScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.94, 1, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));

        // Tiles rise in one after another.
        int i = 0;
        foreach (UIElement tile in _tiles.Children)
        {
            tile.Opacity = 0;
            var delay = TimeSpan.FromMilliseconds(60 + 35 * i++);
            tile.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Fast) { BeginTime = delay });
            if (tile is FrameworkElement fe)
            {
                fe.Margin = new Thickness(10, 34, 10, -14);
                fe.BeginAnimation(MarginProperty, new ThicknessAnimation(new Thickness(10, 34, 10, -14), new Thickness(10), TimeSpan.FromMilliseconds(360))
                {
                    BeginTime = delay, EasingFunction = ease,
                });
            }
        }
    }

    public void CloseAnimated(Action? after = null)
    {
        if (_closing)
            return;
        _closing = true;
        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(140));
        fade.Completed += (_, _) =>
        {
            Close();
            if (after != null)
            {
                // Let the desktop repaint without the overlay before acting (e.g. screenshots).
                Dispatcher.BeginInvoke(async () =>
                {
                    await Task.Delay(120);
                    after();
                });
            }
        };
        BeginAnimation(OpacityProperty, fade);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            CloseAnimated();
            return;
        }
        base.OnKeyDown(e);
    }

    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        // Alt+Tab away (or a click on another monitor) dismisses it, like the Xbox Guide.
        if (!_closing && IsLoaded)
            CloseAnimated();
    }

    private static void Launch(string file, string? args)
    {
        try
        {
            Process.Start(new ProcessStartInfo(file, args ?? "") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warn($"Couldn't open {file}: {ex.Message}");
        }
    }

    private static string FormatSeconds(int seconds) => seconds < 60 ? $"{seconds} s" : $"{seconds / 60} min";
}
