using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Recshot.Native;

namespace Recshot.UI;

/// <summary>A small notice in the bottom-right corner. Useful when acting through hotkeys with the app hidden.</summary>
internal static class Toast
{
    private static Window? _current;

    /// <param name="filePath">If set, clicking the toast shows the file in Explorer.</param>
    public static void Show(string title, string message, string? filePath = null, bool isError = false)
    {
        _current?.Close();

        var accent = isError ? Color.FromRgb(0xEF, 0x44, 0x44) : Color.FromRgb(0x22, 0xC5, 0x5E);
        var panel = new StackPanel { Margin = new Thickness(14, 10, 16, 12) };
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
            Foreground = Brushes.White,
        });
        panel.Children.Add(new TextBlock
        {
            Text = message,
            FontSize = 12,
            Margin = new Thickness(0, 3, 0, 0),
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(Color.FromRgb(0xC8, 0xCC, 0xD4)),
        });
        if (filePath != null)
        {
            panel.Children.Add(new TextBlock
            {
                Text = "Click to show in folder",
                FontSize = 11,
                Margin = new Thickness(0, 5, 0, 0),
                Foreground = new SolidColorBrush(Color.FromRgb(0x8B, 0x93, 0xA1)),
            });
        }

        var card = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(0x1C, 0x1E, 0x25)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(0x33, 0x36, 0x40)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Child = new DockPanel
            {
                Children =
                {
                    new Border { Width = 4, Background = new SolidColorBrush(accent), CornerRadius = new CornerRadius(10, 0, 0, 10) },
                    panel,
                },
            },
        };

        var window = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            ShowActivated = false,
            Topmost = true,
            Width = 340,
            SizeToContent = SizeToContent.Height,
            Content = card,
            Cursor = filePath != null ? System.Windows.Input.Cursors.Hand : null,
        };
        window.SourceInitialized += (_, _) =>
            Win32.SetWindowDisplayAffinity(new WindowInteropHelper(window).Handle, Win32.WDA_EXCLUDEFROMCAPTURE);
        window.Loaded += (_, _) =>
        {
            Rect area = SystemParameters.WorkArea;
            window.Left = area.Right - window.ActualWidth - 16;
            window.Top = area.Bottom - window.ActualHeight - 16;
        };
        window.MouseLeftButtonUp += (_, _) =>
        {
            if (filePath != null)
            {
                try
                {
                    Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{filePath}\"") { UseShellExecute = true });
                }
                catch (Exception ex)
                {
                    Log.Warn($"Explorer launch failed: {ex.Message}");
                }
            }
            window.Close();
        };

        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(isError ? 8 : 4) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            window.Close();
        };
        window.Closed += (_, _) =>
        {
            timer.Stop();
            if (_current == window)
                _current = null;
        };

        _current = window;
        window.Show();
        timer.Start();
    }
}
