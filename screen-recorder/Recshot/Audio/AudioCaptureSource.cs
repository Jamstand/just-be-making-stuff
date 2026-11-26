using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Recshot.Audio;

/// <summary>A chunk of captured audio: interleaved stereo float samples plus when it arrived (Stopwatch ticks).</summary>
internal readonly record struct AudioPacket(long Timestamp, float[] Samples, int Frames);

/// <summary>
/// WASAPI capture of a microphone or of what the speakers are playing (loopback). Always emits
/// stereo float. Windows resamples to 48 kHz for us where it can; otherwise FFmpeg does it later.
/// </summary>
internal sealed class AudioCaptureSource : IDisposable
{
    public const int Channels = 2;
    private const int PreferredRate = 48000;
    private static readonly Guid SubtypeFloat = new("00000003-0000-0010-8000-00aa00389b71");

    private readonly MMDevice _device;
    private readonly WasapiCapture _capture;
    private readonly int _srcChannels;
    private readonly int _srcBits;
    private readonly bool _srcFloat;
    private readonly int _blockAlign;
    private float _peak;
    private volatile bool _disposed;

    public string Name { get; }
    public string DeviceName { get; }
    public int SampleRate { get; }
    public float Gain { get; set; }

    /// <summary>Peak level of recent audio, 0..1, decaying. For the UI meters.</summary>
    public float Level
    {
        get
        {
            float p = _peak;
            _peak = p * 0.6f;
            return Math.Min(1f, p);
        }
    }

    public event Action<AudioPacket>? PacketArrived;
    public event Action<string>? Stopped;

    private AudioCaptureSource(string name, MMDevice device, bool loopback, float gain)
    {
        Name = name;
        Gain = gain;
        _device = device;
        DeviceName = device.FriendlyName;

        // First try: ask Windows for 48 kHz stereo float directly.
        WasapiCapture? capture = null;
        try
        {
            capture = new FlexibleCapture(device, loopback, autoConvert: true)
            {
                WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(PreferredRate, Channels),
            };
            capture.StartRecording();
        }
        catch (Exception ex)
        {
            Log.Info($"{name}: 48 kHz conversion not available ({ex.Message}); using the device format");
            capture?.Dispose();
            capture = new FlexibleCapture(device, loopback, autoConvert: false);
            capture.StartRecording();
        }

        _capture = capture;
        WaveFormat fmt = capture.WaveFormat;
        SampleRate = fmt.SampleRate;
        _srcChannels = fmt.Channels;
        _srcBits = fmt.BitsPerSample;
        _blockAlign = fmt.BlockAlign;
        _srcFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat ||
                    (fmt is WaveFormatExtensible ext && ext.SubFormat == SubtypeFloat);
        if (_srcFloat && _srcBits != 32)
            throw new NotSupportedException($"Unsupported float format: {_srcBits}-bit");

        _capture.DataAvailable += OnData;
        _capture.RecordingStopped += (_, e) =>
        {
            if (!_disposed)
            {
                string why = e.Exception?.Message ?? "the device stopped";
                Log.Warn($"{name} stopped: {why}");
                Stopped?.Invoke($"{name} stopped ({why}).");
            }
        };
        Log.Info($"{name}: {DeviceName}, {SampleRate} Hz, {_srcChannels} ch, {_srcBits}-bit {(_srcFloat ? "float" : "PCM")}");
    }

    public static AudioCaptureSource Create(string name, bool loopback, string? deviceId, float gain)
    {
        using var enumerator = new MMDeviceEnumerator();
        MMDevice? device = null;
        if (!string.IsNullOrEmpty(deviceId))
        {
            try
            {
                device = enumerator.GetDevice(deviceId);
                if (device.State != DeviceState.Active)
                    device = null;
            }
            catch
            {
                device = null;
            }
        }
        device ??= enumerator.GetDefaultAudioEndpoint(loopback ? DataFlow.Render : DataFlow.Capture, Role.Console);
        return new AudioCaptureSource(name, device, loopback, gain);
    }

    public static List<(string Id, string Name)> ListDevices(bool output)
    {
        var list = new List<(string, string)>();
        using var enumerator = new MMDeviceEnumerator();
        foreach (MMDevice d in enumerator.EnumerateAudioEndPoints(output ? DataFlow.Render : DataFlow.Capture, DeviceState.Active))
        {
            using (d)
                list.Add((d.ID, d.FriendlyName));
        }
        return list;
    }

    private unsafe void OnData(object? sender, WaveInEventArgs e)
    {
        if (_disposed || e.BytesRecorded <= 0)
            return;
        long timestamp = Stopwatch.GetTimestamp();
        int frames = e.BytesRecorded / _blockAlign;
        if (frames == 0)
            return;

        var output = new float[frames * Channels];
        float gain = Gain;
        float peak = 0;
        int ch = _srcChannels;

        fixed (byte* raw = e.Buffer)
        {
            for (int f = 0; f < frames; f++)
            {
                byte* frame = raw + (long)f * _blockAlign;
                float l, r;
                if (ch == 1)
                {
                    l = r = Sample(frame, 0);
                }
                else if (ch == 2)
                {
                    l = Sample(frame, 0);
                    r = Sample(frame, 1);
                }
                else
                {
                    // Surround → stereo: FL FR FC LFE BL BR SL SR
                    float c = ch > 2 ? Sample(frame, 2) * 0.7071f : 0;
                    float bl = ch > 4 ? Sample(frame, 4) * 0.5f : 0, br = ch > 5 ? Sample(frame, 5) * 0.5f : 0;
                    float sl = ch > 6 ? Sample(frame, 6) * 0.5f : 0, sr = ch > 7 ? Sample(frame, 7) * 0.5f : 0;
                    l = Sample(frame, 0) + c + bl + sl;
                    r = Sample(frame, 1) + c + br + sr;
                }
                l *= gain;
                r *= gain;
                output[f * 2] = l;
                output[f * 2 + 1] = r;
                float a = Math.Max(Math.Abs(l), Math.Abs(r));
                if (a > peak)
                    peak = a;
            }
        }

        if (peak > _peak)
            _peak = peak;
        PacketArrived?.Invoke(new AudioPacket(timestamp, output, frames));
    }

    private unsafe float Sample(byte* frame, int channel)
    {
        if (_srcFloat)
            return ((float*)frame)[channel];
        switch (_srcBits)
        {
            case 16:
                return ((short*)frame)[channel] / 32768f;
            case 24:
                byte* p = frame + channel * 3;
                int v = (p[0] << 8) | (p[1] << 16) | (p[2] << 24);
                return (v >> 8) / 8388608f;
            case 32:
                return ((int*)frame)[channel] / 2147483648f;
            default:
                return 0;
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        try
        {
            _capture.DataAvailable -= OnData;
            _capture.StopRecording();
        }
        catch (Exception ex)
        {
            Log.Warn($"{Name} stop: {ex.Message}");
        }
        _capture.Dispose();
        _device.Dispose();
    }

    /// <summary>WasapiCapture with a short 20 ms buffer, optional loopback, and optional Windows-side resampling.</summary>
    private sealed class FlexibleCapture : WasapiCapture
    {
        private readonly bool _loopback;
        private readonly bool _autoConvert;

        public FlexibleCapture(MMDevice device, bool loopback, bool autoConvert)
            : base(device, false, 20)
        {
            _loopback = loopback;
            _autoConvert = autoConvert;
        }

        protected override AudioClientStreamFlags GetAudioClientStreamFlags()
        {
            AudioClientStreamFlags flags = base.GetAudioClientStreamFlags();
            if (_loopback)
                flags |= AudioClientStreamFlags.Loopback;
            if (_autoConvert)
                flags |= AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality;
            else
                flags &= ~(AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality);
            return flags;
        }
    }
}
