using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Recshot.Native;

namespace Recshot.UI;

/// <summary>
/// Small always-on-top pill in the top-right corner while recording: pulsing dot, timer, mic state.
/// It ignores the mouse and is excluded from captures, so it never ends up in your video.
/// </summary>
internal sealed class RecordingHud : Window
{
    private readonly Ellipse _dot;
    private readonly TextBlock _time;
    private readonly TextBlock _label;
    private readonly TextBlock _mic;
    private readonly Storyboard _pulse;

    public RecordingHud()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;
        Focusable = false;

        _dot = new Ellipse { Width = 10, Height = 10, Fill = (Brush)Application.Current.FindResource("RecordRed"), VerticalAlignment = VerticalAlignment.Center };
        _label = new TextBlock { Text = "REC", FontSize = 12, FontWeight = FontWeights.Bold, Foreground = Brushes.White, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        _time = new TextBlock
        {
            Text = "00:00:00", FontSize = 13, FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            Foreground = Brushes.White, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        _mic = new TextBlock
        {
            FontFamily = (FontFamily)Application.Current.FindResource("IconFont"), FontSize = 13,
            Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
        };

        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_dot);
        row.Children.Add(_label);
        row.Children.Add(_time);
        row.Children.Add(_mic);

        Content = new Border
        {
            Margin = new Thickness(12), // room for the shadow
            Padding = new Thickness(14, 8, 16, 8),
            CornerRadius = new CornerRadius(18),
            Background = new SolidColorBrush(Color.FromArgb(0xD8, 0x12, 0x13, 0x18)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 2, Opacity = 0.45, Color = Colors.Black },
            Child = row,
        };

        var fade = new DoubleAnimation(1, 0.25, TimeSpan.FromSeconds(0.8)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
        Storyboard.SetTarget(fade, _dot);
        Storyboard.SetTargetProperty(fade, new PropertyPath(OpacityProperty));
        _pulse = new Storyboard();
        _pulse.Children.Add(fade);

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            long ex = Win32.GetWindowLongPtr(hwnd, Win32.GWL_EXSTYLE).ToInt64();
            // Click-through, never activates, not in Alt+Tab.
            Win32.SetWindowLongPtr(hwnd, Win32.GWL_EXSTYLE,
                new IntPtr(ex | Win32.WS_EX_TRANSPARENT | Win32.WS_EX_LAYERED | Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE));
            Win32.SetWindowDisplayAffinity(hwnd, Win32.WDA_EXCLUDEFROMCAPTURE);
        };
        Loaded += (_, _) => Place();
        SizeChanged += (_, _) => Place();
    }

    private void Place()
    {
        Rect area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 8;
        Top = area.Top + 8;
    }

    public void Update(TimeSpan elapsed, bool paused, bool micOn, bool micMuted)
    {
        _time.Text = elapsed.ToString(@"hh\:mm\:ss");
        _label.Text = paused ? "PAUSED" : "REC";
        _dot.Fill = (Brush)Application.Current.FindResource(paused ? "PausedAmber" : "RecordRed");
        if (paused)
        {
            _pulse.Stop();
            _dot.Opacity = 1;
        }
        else if (_pulse.GetCurrentState() != ClockState.Active)
        {
            _pulse.Begin();
        }

        _mic.Visibility = micOn ? Visibility.Visible : Visibility.Collapsed;
        _mic.Text = micMuted ? "" /* MicOff (Fluent) */ : "" /* Microphone */;
        _mic.Foreground = micMuted ? (Brush)Application.Current.FindResource("RecordRed") : Brushes.White;
        if (micMuted && _mic.FontFamily.Source.StartsWith("Segoe Fluent") == false)
            _mic.Text = ""; // MicOff in Segoe MDL2 Assets
    }
}
