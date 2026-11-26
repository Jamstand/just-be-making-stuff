using Recshot.Native;
using Vortice.Direct3D11;
using Windows.Foundation.Metadata;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace Recshot.Capture;

/// <summary>
/// Windows.Graphics.Capture session for a monitor or a single window. Uses the GPU the whole way:
/// each new frame arrives as a D3D11 texture and is handed to <see cref="FrameArrived"/> while
/// <see cref="GpuDevice.Lock"/> is held.
/// </summary>
internal sealed class ScreenCapture : IDisposable
{
    private const DirectXPixelFormat PixelFormat = DirectXPixelFormat.B8G8R8A8UIntNormalized;

    private readonly GpuDevice _gpu;
    private readonly GraphicsCaptureItem _item;
    private readonly Direct3D11CaptureFramePool _pool;
    private readonly GraphicsCaptureSession _session;
    private SizeInt32 _poolSize;
    private bool _disposed;

    /// <summary>(texture, content width, content height). Called on a capture thread with the GPU lock held.</summary>
    public event Action<ID3D11Texture2D, int, int>? FrameArrived;

    /// <summary>Raised when the captured window is closed or the monitor goes away.</summary>
    public event Action? Closed;

    public int Width => _item.Size.Width;
    public int Height => _item.Size.Height;

    private ScreenCapture(GpuDevice gpu, GraphicsCaptureItem item, bool showCursor)
    {
        _gpu = gpu;
        _item = item;
        _poolSize = item.Size;
        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(gpu.WinRTDevice, PixelFormat, 2, _poolSize);
        _pool.FrameArrived += OnFrameArrived;
        _session = _pool.CreateCaptureSession(item);
        _item.Closed += (_, _) => Closed?.Invoke();

        try
        {
            _session.IsCursorCaptureEnabled = showCursor;
        }
        catch (Exception ex)
        {
            Log.Warn($"Couldn't change cursor capture: {ex.Message}");
        }

        // Windows 11 can drop the yellow "being captured" border.
        if (ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
        {
            try
            {
                _session.IsBorderRequired = false;
            }
            catch (Exception ex)
            {
                Log.Info($"Capture border can't be hidden on this system: {ex.Message}");
            }
        }
    }

    public static bool IsSupported => GraphicsCaptureSession.IsSupported();

    /// <summary>Ask once per run for borderless capture (Windows 11). Harmless where unsupported.</summary>
    public static async Task RequestBorderlessAccessAsync()
    {
        try
        {
            if (ApiInformation.IsTypePresent("Windows.Graphics.Capture.GraphicsCaptureAccess"))
                await GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless);
        }
        catch (Exception ex)
        {
            Log.Info($"Borderless capture request not available: {ex.Message}");
        }
    }

    public static ScreenCapture ForMonitor(GpuDevice gpu, IntPtr monitor, bool showCursor)
        => new(gpu, WinRTInterop.CreateItemForMonitor(monitor), showCursor);

    public static ScreenCapture ForWindow(GpuDevice gpu, IntPtr hwnd, bool showCursor)
        => new(gpu, WinRTInterop.CreateItemForWindow(hwnd), showCursor);

    public void Start() => _session.StartCapture();

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        if (_disposed)
            return;

        try
        {
            using Direct3D11CaptureFrame? frame = sender.TryGetNextFrame();
            if (frame == null)
                return;

            SizeInt32 content = frame.ContentSize;
            lock (_gpu.Lock)
            {
                if (_disposed)
                    return;
                using ID3D11Texture2D texture = WinRTInterop.GetTexture(frame.Surface);
                FrameArrived?.Invoke(texture, content.Width, content.Height);
            }

            // A window was resized: rebuild the pool so later frames come at the new size.
            if (content.Width > 0 && content.Height > 0 &&
                (content.Width != _poolSize.Width || content.Height != _poolSize.Height))
            {
                _poolSize = content;
                sender.Recreate(_gpu.WinRTDevice, PixelFormat, 2, content);
            }
        }
        catch (Exception ex)
        {
            Log.Error("Capture frame failed", ex);
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _pool.FrameArrived -= OnFrameArrived;
        try
        {
            _session.Dispose();
            _pool.Dispose();
        }
        catch (Exception ex)
        {
            Log.Warn($"Capture dispose: {ex.Message}");
        }
    }
}
