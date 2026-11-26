using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Recshot.Capture;
using Recshot.Core;
using Recshot.Native;

namespace Recshot.UI;

/// <summary>
/// Full-screen picker shown on every monitor over a frozen screenshot. Drag to pick an area, click to
/// pick the whole monitor, Esc / right-click to cancel. The frozen image doubles as the screenshot.
/// </summary>
internal static class RegionPicker
{
    public sealed record Selection(DisplayInfo Display, RECT Rect, BitmapSource DisplayImage)
    {
        /// <summary>The selected pixels, cropped from the frozen display image.</summary>
        public BitmapSource Crop() => ScreenGrabber.Crop(DisplayImage,
            new Int32Rect(Rect.Left - Display.Bounds.Left, Rect.Top - Display.Bounds.Top, Rect.Width, Rect.Height));
    }

    private static bool _open;

    public static async Task<Selection?> PickAsync(string hint)
    {
        if (_open)
            return null;
        _open = true;
        try
        {
            List<DisplayInfo> displays = ScreenInfo.GetDisplays();
            var shots = displays.Select(d => ScreenGrabber.CaptureScreenRect(d.Bounds)).ToList();
            var tcs = new TaskCompletionSource<Selection?>();
            var windows = new List<OverlayWindow>();

            void Finish(Selection? result)
            {
                if (!tcs.TrySetResult(result))
                    return;
                foreach (OverlayWindow w in windows)
                    w.Close();
            }

            for (int i = 0; i < displays.Count; i++)
            {
                var window = new OverlayWindow(displays[i], shots[i], hint);
                window.Picked += (d, rect, image) => Finish(rect is { } r ? new Selection(d, r, image) : null);
                windows.Add(window);
            }
            foreach (OverlayWindow w in windows)
                w.Show();

            // Give keyboard focus to the monitor the mouse is on so Esc works straight away.
            Win32.GetCursorPos(out POINT cursor);
            OverlayWindow? active = windows.FirstOrDefault(w => w.Contains(cursor.X, cursor.Y)) ?? windows.FirstOrDefault();
            active?.Activate();
            active?.Focus();

            return await tcs.Task;
        }
        finally
        {
            _open = false;
        }
    }

    private sealed class OverlayWindow : Window
    {
        private readonly DisplayInfo _display;
        private readonly BitmapSource _image;
        private readonly Canvas _canvas = new();
        private readonly Path _dim;
        private readonly Rectangle _border;
        private readonly Border _sizeTag;
        private readonly TextBlock _sizeText;
        private Point? _dragStart;
        private Rect _selection;

        public event Action<DisplayInfo, RECT?, BitmapSource>? Picked;

        public OverlayWindow(DisplayInfo display, BitmapSource image, string hint)
        {
            _display = display;
            _image = image;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = true;
            Background = Brushes.Black;
            Cursor = Cursors.Cross;
            ShowActivated = true;
            // Rough placement in DIPs; SourceInitialized snaps it to exact physical pixels.
            Left = display.Bounds.Left;
            Top = display.Bounds.Top;
            Width = Math.Max(1, display.Bounds.Width);
            Height = Math.Max(1, display.Bounds.Height);

            var grid = new Grid();
            grid.Children.Add(new Image { Source = image, Stretch = Stretch.Fill });

            _dim = new Path { Fill = new SolidColorBrush(Color.FromArgb(0x78, 0, 0, 0)), IsHitTestVisible = false };
            _border = new Rectangle
            {
                Stroke = Brushes.White,
                StrokeThickness = 1.5,
                StrokeDashArray = [4, 3],
                Visibility = Visibility.Collapsed,
                IsHitTestVisible = false,
            };
            _sizeText = new TextBlock { Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold };
            _sizeTag = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xD0, 0x10, 0x10, 0x14)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(6, 2, 6, 2),
                Child = _sizeText,
                Visibility = Visibility.Collapsed,
                IsHitTestVisible = false,
            };
            _canvas.Children.Add(_dim);
            _canvas.Children.Add(_border);
            _canvas.Children.Add(_sizeTag);
            grid.Children.Add(_canvas);

            grid.Children.Add(new Border
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 28, 0, 0),
                Padding = new Thickness(14, 8, 14, 8),
                CornerRadius = new CornerRadius(8),
                Background = new SolidColorBrush(Color.FromArgb(0xE0, 0x18, 0x18, 0x1E)),
                IsHitTestVisible = false,
                Child = new TextBlock
                {
                    Text = hint,
                    Foreground = Brushes.White,
                    FontSize = 13,
                },
            });
            Content = grid;

            SourceInitialized += (_, _) =>
            {
                SnapToDisplay();
                Win32.SetWindowDisplayAffinity(new WindowInteropHelper(this).Handle, Win32.WDA_EXCLUDEFROMCAPTURE);
            };
            Loaded += (_, _) =>
            {
                SnapToDisplay();
                UpdateDim();
            };
            SizeChanged += (_, _) => UpdateDim();
        }

        /// <summary>Covers the monitor exactly, in physical pixels, whatever its DPI.</summary>
        private void SnapToDisplay()
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            if (hwnd == IntPtr.Zero)
                return;
            // Moving onto a monitor with a different DPI makes WPF rescale us; the second call corrects that.
            for (int i = 0; i < 2; i++)
                Win32.SetWindowPos(hwnd, Win32.HWND_TOPMOST, _display.Bounds.Left, _display.Bounds.Top,
                    _display.Bounds.Width, _display.Bounds.Height, Win32.SWP_NOACTIVATE);
        }

        public bool Contains(int x, int y)
            => x >= _display.Bounds.Left && x < _display.Bounds.Right && y >= _display.Bounds.Top && y < _display.Bounds.Bottom;

        private void UpdateDim()
        {
            var full = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight));
            _dim.Data = _selection.IsEmpty || _selection.Width < 1
                ? full
                : new CombinedGeometry(GeometryCombineMode.Exclude, full, new RectangleGeometry(_selection));
        }

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            _dragStart = e.GetPosition(this);
            _selection = Rect.Empty;
            CaptureMouse();
            e.Handled = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_dragStart is not { } start)
                return;
            Point p = e.GetPosition(this);
            p = new Point(Math.Clamp(p.X, 0, ActualWidth), Math.Clamp(p.Y, 0, ActualHeight));
            _selection = new Rect(start, p);

            Canvas.SetLeft(_border, _selection.X);
            Canvas.SetTop(_border, _selection.Y);
            _border.Width = _selection.Width;
            _border.Height = _selection.Height;
            _border.Visibility = Visibility.Visible;

            RECT phys = ToPhysical(_selection);
            _sizeText.Text = $"{phys.Width} × {phys.Height}";
            _sizeTag.Visibility = Visibility.Visible;
            Canvas.SetLeft(_sizeTag, _selection.X);
            Canvas.SetTop(_sizeTag, _selection.Y > 30 ? _selection.Y - 26 : _selection.Bottom + 6);
            UpdateDim();
        }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            if (_dragStart == null)
                return;
            ReleaseMouseCapture();
            _dragStart = null;
            RECT rect = _selection.IsEmpty || _selection.Width < 4 || _selection.Height < 4
                ? _display.Bounds // a click picks the whole monitor
                : ToPhysical(_selection);
            Picked?.Invoke(_display, rect, _image);
        }

        protected override void OnMouseRightButtonUp(MouseButtonEventArgs e) => Picked?.Invoke(_display, null, _image);

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
                Picked?.Invoke(_display, null, _image);
            else if (e.Key == Key.Enter && !_selection.IsEmpty && _selection.Width >= 4)
                Picked?.Invoke(_display, ToPhysical(_selection), _image);
        }

        /// <summary>Window DIPs → physical screen pixels, clamped to this monitor, even-sized for video.</summary>
        private RECT ToPhysical(Rect r)
        {
            double sx = _display.Bounds.Width / Math.Max(1, ActualWidth);
            double sy = _display.Bounds.Height / Math.Max(1, ActualHeight);
            int left = _display.Bounds.Left + (int)Math.Round(r.Left * sx);
            int top = _display.Bounds.Top + (int)Math.Round(r.Top * sy);
            int right = _display.Bounds.Left + (int)Math.Round(r.Right * sx);
            int bottom = _display.Bounds.Top + (int)Math.Round(r.Bottom * sy);
            left = Math.Clamp(left, _display.Bounds.Left, _display.Bounds.Right);
            top = Math.Clamp(top, _display.Bounds.Top, _display.Bounds.Bottom);
            right = Math.Clamp(right, left, _display.Bounds.Right);
            bottom = Math.Clamp(bottom, top, _display.Bounds.Bottom);
            return new RECT(left, top, right, bottom);
        }
    }
}
