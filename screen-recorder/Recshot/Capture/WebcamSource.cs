using System.Runtime.InteropServices;
using Windows.Devices.Enumeration;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using WinRT;

namespace Recshot.Capture;

/// <summary>
/// Pulls BGRA frames from a webcam with MediaCapture + MediaFrameReader and keeps only the newest one.
/// The compositor uploads it to the GPU each output frame.
/// </summary>
internal sealed class WebcamSource : IDisposable
{
    private static readonly Guid IID_IMemoryBufferByteAccess = new("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D");

    private readonly MediaCapture _capture;
    private readonly MediaFrameReader _reader;
    private readonly object _gate = new();
    private byte[]? _pixels;
    private int _width, _height;
    private long _version;
    private bool _disposed;

    private WebcamSource(MediaCapture capture, MediaFrameReader reader)
    {
        _capture = capture;
        _reader = reader;
        _reader.FrameArrived += OnFrameArrived;
    }

    public static async Task<List<(string Id, string Name)>> ListAsync()
    {
        var devices = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture);
        return devices.Where(d => d.IsEnabled).Select(d => (d.Id, d.Name)).ToList();
    }

    public static async Task<WebcamSource> StartAsync(string deviceId)
    {
        bool exclusive = true;
        MediaCapture? capture = await InitializeAsync(deviceId, MediaCaptureSharingMode.ExclusiveControl);
        if (capture == null)
        {
            exclusive = false;
            capture = await InitializeAsync(deviceId, MediaCaptureSharingMode.SharedReadOnly)
                      ?? throw new InvalidOperationException(
                          "Couldn't open the webcam. Is another app using it, or is camera access turned off in Windows privacy settings?");
        }

        MediaFrameSource source = capture.FrameSources.Values
            .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
            .OrderBy(s => s.Info.MediaStreamType switch
            {
                Windows.Media.Capture.MediaStreamType.VideoRecord => 0,
                Windows.Media.Capture.MediaStreamType.VideoPreview => 1,
                _ => 2,
            })
            .FirstOrDefault() ?? throw new InvalidOperationException("That camera has no colour video stream.");

        // A bubble in the corner doesn't need more than ~720p; prefer 30fps or better.
        if (exclusive)
        {
            MediaFrameFormat? best = source.SupportedFormats
                .Where(f => f.VideoFormat.Width >= 320 && f.VideoFormat.Height >= 240)
                .OrderBy(f => Math.Abs((int)f.VideoFormat.Height - 720))
                .ThenByDescending(f => Fps(f) >= 29.5 ? 1 : 0)
                .ThenBy(f => Math.Abs(Fps(f) - 30))
                .FirstOrDefault();
            if (best != null)
            {
                try
                {
                    await source.SetFormatAsync(best);
                }
                catch (Exception ex)
                {
                    Log.Warn($"Webcam format change failed, using its default: {ex.Message}");
                }
            }
        }

        MediaFrameReader reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
        reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
        var webcam = new WebcamSource(capture, reader);
        MediaFrameReaderStartStatus status = await reader.StartAsync();
        if (status != MediaFrameReaderStartStatus.Success)
        {
            webcam.Dispose();
            throw new InvalidOperationException($"Webcam didn't start ({status}).");
        }
        var fmt = source.CurrentFormat?.VideoFormat;
        Log.Info($"Webcam started: {fmt?.Width}x{fmt?.Height}");
        return webcam;
    }

    private static double Fps(MediaFrameFormat f)
        => f.FrameRate == null || f.FrameRate.Denominator == 0 ? 0 : (double)f.FrameRate.Numerator / f.FrameRate.Denominator;

    private static async Task<MediaCapture?> InitializeAsync(string deviceId, MediaCaptureSharingMode mode)
    {
        var capture = new MediaCapture();
        try
        {
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                VideoDeviceId = deviceId,
                StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                SharingMode = mode,
            });
            return capture;
        }
        catch (Exception ex)
        {
            Log.Warn($"Webcam init ({mode}) failed: {ex.Message}");
            capture.Dispose();
            return null;
        }
    }

    private void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        try
        {
            using MediaFrameReference? frame = sender.TryAcquireLatestFrame();
            SoftwareBitmap? bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (bitmap == null)
                return;

            SoftwareBitmap? converted = null;
            if (bitmap.BitmapPixelFormat != BitmapPixelFormat.Bgra8)
                bitmap = converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);

            try
            {
                CopyPixels(bitmap);
            }
            finally
            {
                converted?.Dispose();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Webcam frame dropped: {ex.Message}");
        }
    }

    private unsafe void CopyPixels(SoftwareBitmap bitmap)
    {
        using BitmapBuffer buffer = bitmap.LockBuffer(BitmapBufferAccessMode.Read);
        BitmapPlaneDescription plane = buffer.GetPlaneDescription(0);
        using IMemoryBufferReference reference = buffer.CreateReference();

        IntPtr unknown = MarshalInspectable<IMemoryBufferReference>.FromManaged(reference);
        try
        {
            Guid iid = IID_IMemoryBufferByteAccess;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, in iid, out IntPtr access));
            try
            {
                // IMemoryBufferByteAccess : IUnknown { GetBuffer(BYTE** value, UINT32* capacity) (slot 3) }
                IntPtr* vtbl = *(IntPtr**)access;
                var getBuffer = (delegate* unmanaged[Stdcall]<IntPtr, byte**, uint*, int>)vtbl[3];
                byte* data;
                uint capacity;
                Marshal.ThrowExceptionForHR(getBuffer(access, &data, &capacity));

                int w = plane.Width, h = plane.Height, stride = plane.Stride, rowBytes = w * 4;
                if (w <= 0 || h <= 0 || (long)plane.StartIndex + (long)stride * (h - 1) + rowBytes > capacity)
                    return;

                lock (_gate)
                {
                    if (_pixels == null || _pixels.Length != rowBytes * h)
                        _pixels = new byte[rowBytes * h];
                    fixed (byte* dst = _pixels)
                    {
                        byte* src = data + plane.StartIndex;
                        for (int y = 0; y < h; y++)
                            Buffer.MemoryCopy(src + (long)y * stride, dst + (long)y * rowBytes, rowBytes, rowBytes);
                    }
                    _width = w;
                    _height = h;
                    _version++;
                }
            }
            finally
            {
                Marshal.Release(access);
            }
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }

    /// <summary>
    /// If a frame newer than <paramref name="seenVersion"/> exists, calls <paramref name="use"/> with it
    /// (pixels, width, height) while the buffer is locked, and returns true.
    /// </summary>
    public bool TryUseLatest(ref long seenVersion, Action<byte[], int, int> use)
    {
        lock (_gate)
        {
            if (_pixels == null || _version == seenVersion)
                return false;
            seenVersion = _version;
            use(_pixels, _width, _height);
            return true;
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _reader.FrameArrived -= OnFrameArrived;
        try
        {
            _reader.StopAsync().AsTask().Wait(2000);
        }
        catch (Exception ex)
        {
            Log.Warn($"Webcam stop: {ex.Message}");
        }
        _reader.Dispose();
        _capture.Dispose();
    }
}
