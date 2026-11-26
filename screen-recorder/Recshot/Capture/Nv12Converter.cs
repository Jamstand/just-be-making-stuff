using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Recshot.Capture;

/// <summary>
/// Converts the composed BGRA frame to NV12 (BT.709, limited range) with the GPU's video processor.
/// This keeps colour conversion off the CPU and cuts the bytes read back per frame by 62%.
/// </summary>
internal sealed class Nv12Converter : IDisposable
{
    private readonly ID3D11VideoDevice _videoDevice;
    private readonly ID3D11VideoContext _videoContext;
    private readonly ID3D11VideoProcessorEnumerator _enumerator;
    private readonly ID3D11VideoProcessor _processor;
    private readonly ID3D11VideoProcessorInputView _inputView;
    private readonly ID3D11VideoProcessorOutputView _outputView;
    private readonly VideoProcessorStream[] _streams;

    public ID3D11Texture2D Output { get; }

    private Nv12Converter(GpuDevice gpu, ID3D11Texture2D input, int width, int height, int fps)
    {
        _videoDevice = gpu.Device.QueryInterface<ID3D11VideoDevice>();
        _videoContext = gpu.Context.QueryInterface<ID3D11VideoContext>();

        var content = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputFrameRate = new Rational((uint)fps, 1),
            InputWidth = (uint)width,
            InputHeight = (uint)height,
            OutputFrameRate = new Rational((uint)fps, 1),
            OutputWidth = (uint)width,
            OutputHeight = (uint)height,
            Usage = VideoUsage.OptimalQuality,
        };
        _enumerator = _videoDevice.CreateVideoProcessorEnumerator(content);
        _processor = _videoDevice.CreateVideoProcessor(_enumerator, 0);

        Output = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.NV12,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.RenderTarget,
        });

        _inputView = _videoDevice.CreateVideoProcessorInputView(input, _enumerator, new VideoProcessorInputViewDescription
        {
            FourCC = 0,
            ViewDimension = VideoProcessorInputViewDimension.Texture2D,
            Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 },
        });
        _outputView = _videoDevice.CreateVideoProcessorOutputView(Output, _enumerator, new VideoProcessorOutputViewDescription
        {
            ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
            Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
        });

        _videoContext.VideoProcessorSetStreamFrameFormat(_processor, 0, VideoFrameFormat.Progressive);
        // No driver "enhancements" (denoise, edge sharpening...) on screen content.
        _videoContext.VideoProcessorSetStreamAutoProcessingMode(_processor, 0, false);
        var full = new Vortice.RawRect(0, 0, width, height);
        _videoContext.VideoProcessorSetStreamSourceRect(_processor, 0, true, full);
        _videoContext.VideoProcessorSetStreamDestRect(_processor, 0, true, full);
        _videoContext.VideoProcessorSetOutputTargetRect(_processor, true, full);

        using (var context1 = _videoContext.QueryInterfaceOrNull<ID3D11VideoContext1>())
        {
            if (context1 != null)
            {
                context1.VideoProcessorSetStreamColorSpace1(_processor, 0, ColorSpaceType.RgbFullG22NoneP709);
                context1.VideoProcessorSetOutputColorSpace1(_processor, ColorSpaceType.YcbcrStudioG22LeftP709);
            }
            else
            {
                Log.Warn("ID3D11VideoContext1 missing; relying on driver default colour space");
            }
        }

        _streams = [new VideoProcessorStream { Enable = true, InputSurface = _inputView }];
    }

    /// <summary>Returns null when this GPU/driver can't do BGRA→NV12; the caller falls back to CPU conversion.</summary>
    public static Nv12Converter? TryCreate(GpuDevice gpu, ID3D11Texture2D input, int width, int height, int fps)
    {
        if (!gpu.HasVideoSupport)
            return null;
        try
        {
            var converter = new Nv12Converter(gpu, input, width, height, fps);
            converter.Convert(); // fail fast if the driver rejects it
            return converter;
        }
        catch (Exception ex)
        {
            Log.Warn($"GPU NV12 conversion unavailable, using CPU conversion instead: {ex.Message}");
            return null;
        }
    }

    public void Convert()
    {
        _videoContext.VideoProcessorBlt(_processor, _outputView, 0, 1, _streams).CheckError();
    }

    public void Dispose()
    {
        _inputView.Dispose();
        _outputView.Dispose();
        Output.Dispose();
        _processor.Dispose();
        _enumerator.Dispose();
        _videoContext.Dispose();
        _videoDevice.Dispose();
    }
}
