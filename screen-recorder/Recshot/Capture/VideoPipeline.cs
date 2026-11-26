using System.Diagnostics;
using System.Numerics;
using Recshot.Core;
using Recshot.Native;
using Vortice;
using Vortice.DCommon;
using Vortice.Direct2D1;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using AlphaMode = Vortice.DCommon.AlphaMode;

namespace Recshot.Capture;

/// <summary>Something that consumes raw frames (an FFmpeg encode session).</summary>
internal interface IVideoSink
{
    /// <summary>
    /// A new output frame. <paramref name="repeat"/> is how many frame slots it fills (more than 1 when the
    /// renderer fell behind), which keeps the video timeline locked to wall-clock time. Sinks AddRef what they keep.
    /// </summary>
    void OnVideoFrame(FrameBuffer frame, int repeat);
}

/// <summary>
/// Turns captured screen frames into encoder-ready raw frames at a constant frame rate:
/// capture texture → crop/scale + click rings + webcam bubble (Direct2D) → NV12 (GPU video processor)
/// → CPU readback → every attached <see cref="IVideoSink"/>.
/// </summary>
internal sealed unsafe class VideoPipeline : IDisposable
{
    private const double ClickLifetime = 0.55;

    private readonly GpuDevice _gpu;
    private readonly PipelineConfig _cfg;
    private readonly ScreenCapture _capture;
    private readonly WebcamSource? _webcam;
    private readonly ClickTracker? _clicks;
    private readonly int _cropX, _cropY, _cropW, _cropH;

    private ID3D11Texture2D? _srcTex;
    private ID2D1Bitmap1? _srcBitmap;
    private int _srcW, _srcH;
    private bool _hasFrame;

    private readonly ID3D11Texture2D _composeTex;
    private readonly ID2D1Bitmap1 _composeTarget;
    private readonly Nv12Converter? _nv12;
    private readonly ID3D11Texture2D[] _staging = new ID3D11Texture2D[2];
    private readonly bool[] _stagingFilled = new bool[2];
    private int _stagingIndex;
    private readonly ID2D1SolidColorBrush _brush;

    private ID2D1Bitmap1? _camBitmap;
    private ID2D1BitmapBrush1? _camBrush;
    private int _camW, _camH;
    private long _camVersion = -1;

    private readonly List<ClickTracker.Click> _clickScratch = new();
    private RawRectF _dest;

    private readonly FramePool _pool;
    private readonly object _sinkGate = new();
    private IVideoSink[] _sinks = [];
    private Thread? _thread;
    private volatile bool _running;
    private bool _faultRaised;

    public int Width { get; }
    public int Height { get; }
    public int Fps { get; }
    public VideoPixelFormat PixelFormat { get; }
    public long LateFrames { get; private set; }

    /// <summary>Raised (once) when capture can't continue, e.g. the window was closed.</summary>
    public event Action<string>? Faulted;

    public VideoPipeline(GpuDevice gpu, PipelineConfig cfg, WebcamSource? webcam, ClickTracker? clicks)
    {
        _gpu = gpu;
        _cfg = cfg;
        _webcam = webcam;
        _clicks = clicks;
        Fps = cfg.Fps;

        CaptureTarget target = cfg.Target;
        _capture = target.Kind == SourceKind.Window
            ? ScreenCapture.ForWindow(gpu, target.Window, cfg.ShowCursor)
            : ScreenCapture.ForMonitor(gpu, target.Monitor, cfg.ShowCursor);

        int srcW, srcH;
        if (target.Kind == SourceKind.Region)
        {
            _cropX = Math.Max(0, target.Region.Left - target.MonitorBounds.Left);
            _cropY = Math.Max(0, target.Region.Top - target.MonitorBounds.Top);
            _cropW = Math.Min(target.Region.Width, _capture.Width - _cropX);
            _cropH = Math.Min(target.Region.Height, _capture.Height - _cropY);
            srcW = _cropW;
            srcH = _cropH;
        }
        else
        {
            _cropW = srcW = _capture.Width;
            _cropH = srcH = _capture.Height;
        }
        if (srcW < 2 || srcH < 2)
            throw new InvalidOperationException("The capture area is empty. Is the window minimised?");

        (Width, Height) = OutputSize(srcW, srcH, cfg.MaxHeight, cfg.Encoder.Encoder.Codec);

        _composeTex = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)Width,
            Height = (uint)Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
        });
        using (var surface = _composeTex.QueryInterface<IDXGISurface>())
        {
            _composeTarget = gpu.D2D.CreateBitmapFromDxgiSurface(surface, new BitmapProperties1(
                new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Premultiplied), 96, 96,
                BitmapOptions.Target | BitmapOptions.CannotDraw));
        }
        _brush = gpu.D2D.CreateSolidColorBrush(new Color4(1f, 1f, 1f, 1f));

        lock (gpu.Lock)
            _nv12 = Nv12Converter.TryCreate(gpu, _composeTex, Width, Height, Fps);
        PixelFormat = _nv12 != null ? VideoPixelFormat.Nv12 : VideoPixelFormat.Bgra;

        for (int i = 0; i < _staging.Length; i++)
        {
            _staging[i] = gpu.Device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)Width,
                Height = (uint)Height,
                MipLevels = 1,
                ArraySize = 1,
                Format = PixelFormat == VideoPixelFormat.Nv12 ? Format.NV12 : Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Staging,
                CPUAccessFlags = CpuAccessFlags.Read,
            });
        }

        int frameSize = PixelFormat == VideoPixelFormat.Nv12 ? Width * Height * 3 / 2 : Width * Height * 4;
        _pool = new FramePool(frameSize);

        _capture.FrameArrived += OnCaptured;
        _capture.Closed += () => RaiseFault("The window you were recording was closed.");
        Log.Info($"Video pipeline: {target.Description}, source {srcW}x{srcH} → {Width}x{Height} @ {Fps} fps, {PixelFormat}");
    }

    /// <summary>Output size: optional downscale to <paramref name="maxHeight"/>, H.264's 4096px limit, even dimensions.</summary>
    public static (int Width, int Height) OutputSize(int srcW, int srcH, int maxHeight, string codec)
    {
        double scale = 1;
        if (maxHeight > 0 && srcH > maxHeight)
            scale = (double)maxHeight / srcH;
        if (codec == "h264")
            scale = Math.Min(scale, Math.Min(4096.0 / srcW, 4096.0 / srcH));
        int w = (int)Math.Round(srcW * scale) & ~1;
        int h = (int)Math.Round(srcH * scale) & ~1;
        // Hardware encoders refuse tiny frames; small regions get letterboxed instead.
        return (Math.Max(w, 160), Math.Max(h, 128));
    }

    public void AddSink(IVideoSink sink)
    {
        lock (_sinkGate)
            _sinks = [.. _sinks, sink];
    }

    public void RemoveSink(IVideoSink sink)
    {
        lock (_sinkGate)
            _sinks = _sinks.Where(s => s != sink).ToArray();
    }

    public void Start()
    {
        _running = true;
        _capture.Start();
        _thread = new Thread(RenderLoop) { Name = "Recshot render", IsBackground = true, Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    private void RaiseFault(string message)
    {
        if (_faultRaised)
            return;
        _faultRaised = true;
        Log.Warn($"Video pipeline fault: {message}");
        Faulted?.Invoke(message);
    }

    // Capture thread, GPU lock held.
    private void OnCaptured(ID3D11Texture2D texture, int contentW, int contentH)
    {
        Texture2DDescription desc = texture.Description;
        int x, y, w, h;
        if (_cfg.Target.Kind == SourceKind.Window)
        {
            x = 0;
            y = 0;
            w = Math.Min(contentW, (int)desc.Width);
            h = Math.Min(contentH, (int)desc.Height);
        }
        else
        {
            x = _cropX;
            y = _cropY;
            w = Math.Min(_cropW, (int)desc.Width - x);
            h = Math.Min(_cropH, (int)desc.Height - y);
        }
        if (w <= 0 || h <= 0)
            return;

        EnsureSourceTexture(w, h);
        _gpu.Context.CopySubresourceRegion(_srcTex!, 0, 0, 0, 0, texture, 0, new Box(x, y, 0, x + w, y + h, 1));
        _hasFrame = true;
    }

    private void EnsureSourceTexture(int w, int h)
    {
        if (_srcTex != null && _srcW == w && _srcH == h)
            return;
        _srcBitmap?.Dispose();
        _srcTex?.Dispose();
        _srcTex = _gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w,
            Height = (uint)h,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource,
        });
        using var surface = _srcTex.QueryInterface<IDXGISurface>();
        // Alpha is ignored: some apps leave it at 0, which would otherwise draw as black.
        _srcBitmap = _gpu.D2D.CreateBitmapFromDxgiSurface(surface, new BitmapProperties1(
            new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Ignore), 96, 96, BitmapOptions.None));
        _srcW = w;
        _srcH = h;
    }

    private void RenderLoop()
    {
        Win32.timeBeginPeriod(1);
        long freq = Stopwatch.Frequency;
        long t0 = Stopwatch.GetTimestamp();
        long index = 0;
        int errors = 0;
        FrameBuffer? last = null;

        try
        {
            while (_running)
            {
                long due = t0 + (long)((index + 1) * (double)freq / Fps);
                WaitUntil(due);
                if (!_running)
                    break;

                long elapsedSlots = (long)((Stopwatch.GetTimestamp() - t0) * (double)Fps / freq);
                long repeat = Math.Max(1, elapsedSlots - index);
                if (repeat > Fps * 2L)
                {
                    // We stalled for seconds (sleep/hibernate, a debugger). Don't flood the encoder with copies.
                    Log.Warn($"Render stalled for {repeat} frames");
                    repeat = Fps * 2L;
                    index = elapsedSlots - repeat;
                }
                index += repeat;
                if (repeat > 1)
                    LateFrames += repeat - 1;

                FrameBuffer? fresh = null;
                try
                {
                    fresh = RenderFrame();
                    errors = 0;
                }
                catch (Exception ex)
                {
                    Log.Error("Render failed", ex);
                    if (++errors > Fps * 2)
                    {
                        RaiseFault($"The graphics device stopped working ({ex.Message}).");
                        break;
                    }
                }

                if (fresh != null)
                {
                    last?.Release();
                    last = fresh;
                }
                if (last != null)
                {
                    foreach (IVideoSink sink in _sinks)
                        sink.OnVideoFrame(last, (int)repeat);
                }
            }
        }
        finally
        {
            last?.Release();
            Win32.timeEndPeriod(1);
        }
    }

    private static void WaitUntil(long due)
    {
        while (true)
        {
            long remaining = due - Stopwatch.GetTimestamp();
            if (remaining <= 0)
                return;
            double ms = remaining * 1000.0 / Stopwatch.Frequency;
            if (ms > 2.0)
                Thread.Sleep((int)(ms - 1.0));
            else
                Thread.Yield();
        }
    }

    /// <summary>Composes the current frame and returns the one composed on the previous tick (read back without stalling).</summary>
    private FrameBuffer? RenderFrame()
    {
        lock (_gpu.Lock)
        {
            ID2D1DeviceContext d2d = _gpu.D2D;
            UpdateWebcamBitmap(d2d);

            d2d.Target = _composeTarget;
            d2d.BeginDraw();
            d2d.Transform = Matrix3x2.Identity;
            d2d.Clear(new Color4(0f, 0f, 0f, 1f));
            if (_srcBitmap != null && _hasFrame)
            {
                _dest = Fit(_srcW, _srcH, Width, Height);
                bool oneToOne = Math.Abs(_dest.Right - _dest.Left - _srcW) < 0.5f && Math.Abs(_dest.Bottom - _dest.Top - _srcH) < 0.5f;
                d2d.DrawBitmap(_srcBitmap, _dest, 1f,
                    oneToOne ? InterpolationMode.NearestNeighbor : InterpolationMode.HighQualityCubic, null, null);
                DrawClicks(d2d);
            }
            DrawWebcam(d2d);
            d2d.EndDraw().CheckError();
            d2d.Target = null;

            ID3D11Texture2D readFrom;
            if (_nv12 != null)
            {
                _nv12.Convert();
                readFrom = _nv12.Output;
            }
            else
            {
                readFrom = _composeTex;
            }

            int current = _stagingIndex;
            _gpu.Context.CopyResource(_staging[current], readFrom);
            _stagingFilled[current] = true;
            int previous = current ^ 1;
            _stagingIndex = previous;
            return _stagingFilled[previous] ? ReadBack(_staging[previous]) : null;
        }
    }

    private FrameBuffer ReadBack(ID3D11Texture2D staging)
    {
        MappedSubresource map = _gpu.Context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        FrameBuffer frame = _pool.Rent();
        try
        {
            byte* src = (byte*)map.DataPointer;
            long pitch = map.RowPitch;
            fixed (byte* dst = frame.Data)
            {
                if (PixelFormat == VideoPixelFormat.Nv12)
                {
                    // Luma plane, then the interleaved UV plane, which starts RowPitch * Height bytes in.
                    for (int y = 0; y < Height; y++)
                        Buffer.MemoryCopy(src + y * pitch, dst + (long)y * Width, Width, Width);
                    byte* srcUv = src + pitch * Height;
                    byte* dstUv = dst + (long)Width * Height;
                    for (int y = 0; y < Height / 2; y++)
                        Buffer.MemoryCopy(srcUv + y * pitch, dstUv + (long)y * Width, Width, Width);
                }
                else
                {
                    int row = Width * 4;
                    for (int y = 0; y < Height; y++)
                        Buffer.MemoryCopy(src + y * pitch, dst + (long)y * row, row, row);
                }
            }
            return frame;
        }
        catch
        {
            frame.Release();
            throw;
        }
        finally
        {
            _gpu.Context.Unmap(staging, 0);
        }
    }

    private static RawRectF Fit(int srcW, int srcH, int dstW, int dstH)
    {
        double scale = Math.Min((double)dstW / srcW, (double)dstH / srcH);
        // Never upscale a region/window that shrank below the output size by more than needed; keep pixels sharp at 1:1.
        if (Math.Abs(scale - 1) < 0.002)
            scale = 1;
        float w = (float)(srcW * scale), h = (float)(srcH * scale);
        float x = MathF.Round((dstW - w) / 2), y = MathF.Round((dstH - h) / 2);
        return new RawRectF(x, y, x + w, y + h);
    }

    private (int X, int Y) CaptureOrigin()
    {
        CaptureTarget t = _cfg.Target;
        return t.Kind switch
        {
            SourceKind.Region => (t.Region.Left, t.Region.Top),
            SourceKind.Window => Win32.GetVisibleWindowBounds(t.Window) is var r ? (r.Left, r.Top) : (0, 0),
            _ => (t.MonitorBounds.Left, t.MonitorBounds.Top),
        };
    }

    private void DrawClicks(ID2D1DeviceContext d2d)
    {
        if (_clicks == null)
            return;
        _clicks.GetRecent(ClickLifetime, _clickScratch);
        if (_clickScratch.Count == 0)
            return;

        (int ox, int oy) = CaptureOrigin();
        float scale = (_dest.Right - _dest.Left) / _srcW;
        float unit = Math.Max(0.6f, Height / 1080f);
        long now = Stopwatch.GetTimestamp();

        foreach (ClickTracker.Click click in _clickScratch)
        {
            float x = _dest.Left + (click.X - ox) * scale;
            float y = _dest.Top + (click.Y - oy) * scale;
            if (x < _dest.Left - 40 || x > _dest.Right + 40 || y < _dest.Top - 40 || y > _dest.Bottom + 40)
                continue;

            float p = (float)Math.Clamp((now - click.Timestamp) / (double)Stopwatch.Frequency / ClickLifetime, 0, 1);
            float ease = 1 - (1 - p) * (1 - p);
            float radius = (12 + 26 * ease) * unit;
            var (r, g, b) = click.IsRight ? (0.25f, 0.62f, 1f) : (1f, 0.78f, 0.12f);
            var center = new Vector2(x, y);

            _brush.Color = new Color4(r, g, b, 0.28f * (1 - p));
            d2d.FillEllipse(new Ellipse(center, radius, radius), _brush);
            _brush.Color = new Color4(r, g, b, 0.95f * (1 - p));
            d2d.DrawEllipse(new Ellipse(center, radius, radius), _brush, 3.5f * unit);
        }
    }

    private void UpdateWebcamBitmap(ID2D1DeviceContext d2d)
    {
        _webcam?.TryUseLatest(ref _camVersion, (pixels, w, h) =>
        {
            if (_camBitmap == null || _camW != w || _camH != h)
            {
                _camBrush?.Dispose();
                _camBitmap?.Dispose();
                _camBitmap = d2d.CreateBitmap(new SizeI(w, h), IntPtr.Zero, 0, new BitmapProperties1(
                    new Vortice.DCommon.PixelFormat(Format.B8G8R8A8_UNorm, AlphaMode.Ignore), 96, 96, BitmapOptions.None));
                _camBrush = d2d.CreateBitmapBrush(_camBitmap,
                    new BitmapBrushProperties1(ExtendMode.Clamp, ExtendMode.Clamp, InterpolationMode.HighQualityCubic));
                _camW = w;
                _camH = h;
            }
            fixed (byte* p = pixels)
                _camBitmap.CopyFromMemory((IntPtr)p, (uint)(w * 4)).CheckError();
        });
    }

    private void DrawWebcam(ID2D1DeviceContext d2d)
    {
        WebcamOptions? opt = _cfg.Webcam;
        if (opt == null || _camBrush == null || _camW == 0)
            return;

        float size = Height * (float)opt.SizeFraction;
        float bh = size;
        float bw = opt.Shape == WebcamShape.Circle ? size : Math.Min(size * _camW / _camH, size * 2f);
        float margin = Height * 0.03f;
        float bx = opt.Corner is WebcamCorner.BottomLeft or WebcamCorner.TopLeft ? margin : Width - margin - bw;
        float by = opt.Corner is WebcamCorner.TopLeft or WebcamCorner.TopRight ? margin : Height - margin - bh;

        // Cover-fit the camera image into the bubble, centred, optionally mirrored like a selfie view.
        float s = Math.Max(bw / _camW, bh / _camH);
        float dw = _camW * s, dh = _camH * s;
        float ox = bx + (bw - dw) / 2, oy = by + (bh - dh) / 2;
        _camBrush.Transform = opt.Mirror
            ? Matrix3x2.CreateScale(-s, s) * Matrix3x2.CreateTranslation(ox + dw, oy)
            : Matrix3x2.CreateScale(s, s) * Matrix3x2.CreateTranslation(ox, oy);

        float border = Math.Max(2f, size * 0.014f);
        float shadow = size * 0.02f;
        if (opt.Shape == WebcamShape.Circle)
        {
            var center = new Vector2(bx + bw / 2, by + bh / 2);
            _brush.Color = new Color4(0f, 0f, 0f, 0.35f);
            d2d.FillEllipse(new Ellipse(center + new Vector2(0, shadow), bw / 2 + shadow / 2, bh / 2 + shadow / 2), _brush);
            d2d.FillEllipse(new Ellipse(center, bw / 2, bh / 2), _camBrush);
            _brush.Color = new Color4(1f, 1f, 1f, 0.92f);
            d2d.DrawEllipse(new Ellipse(center, bw / 2 - border / 2, bh / 2 - border / 2), _brush, border);
        }
        else
        {
            float radius = size * 0.08f;
            _brush.Color = new Color4(0f, 0f, 0f, 0.35f);
            d2d.FillRoundedRectangle(new RoundedRectangle(new System.Drawing.RectangleF(bx, by + shadow, bw, bh), radius, radius), _brush);
            d2d.FillRoundedRectangle(new RoundedRectangle(new System.Drawing.RectangleF(bx, by, bw, bh), radius, radius), _camBrush);
            _brush.Color = new Color4(1f, 1f, 1f, 0.92f);
            d2d.DrawRoundedRectangle(new RoundedRectangle(
                new System.Drawing.RectangleF(bx + border / 2, by + border / 2, bw - border, bh - border), radius, radius), _brush, border);
        }
    }

    public void Dispose()
    {
        _running = false;
        _thread?.Join(3000);
        _capture.Dispose();
        lock (_gpu.Lock)
        {
            _gpu.D2D.Target = null;
            _camBrush?.Dispose();
            _camBitmap?.Dispose();
            _brush.Dispose();
            _srcBitmap?.Dispose();
            _srcTex?.Dispose();
            _composeTarget.Dispose();
            _nv12?.Dispose();
            _composeTex.Dispose();
            foreach (ID3D11Texture2D s in _staging)
                s?.Dispose();
            _gpu.Context.Flush();
        }
    }
}
