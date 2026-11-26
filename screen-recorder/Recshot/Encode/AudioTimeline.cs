using System.IO;
using System.Runtime.InteropServices;

namespace Recshot.Encode;

/// <summary>
/// Places captured audio packets on the recording's clock and writes a gap-free stream.
///
/// Every packet carries the sample position where it *should* start (from its arrival time).
/// Small differences are jitter and are ignored. Bigger ones are corrected:
///  - packet starts later than what's written → silence is inserted (loopback sends nothing while
///    nothing plays; or the device clock runs slow);
///  - packet overlaps what's already written → the overlap is dropped (device clock runs fast, or the
///    packet arrived after silence was already padded in its place).
/// <see cref="PadTo"/> keeps the stream advancing in real time while a device is silent.
/// </summary>
internal sealed class AudioTimeline
{
    public const int Channels = 2;
    private readonly byte[] _silence;
    private readonly long _tolerance;

    public int SampleRate { get; }
    public long Written { get; private set; }
    public long InsertedSilence { get; private set; }
    public long DroppedFrames { get; private set; }

    public AudioTimeline(int sampleRate, double toleranceSeconds = 0.040)
    {
        SampleRate = sampleRate;
        _tolerance = (long)(sampleRate * toleranceSeconds);
        _silence = new byte[sampleRate / 10 * Channels * sizeof(float)];
    }

    /// <param name="samples">Interleaved stereo float samples.</param>
    /// <param name="expectedStart">Sample position (on the session clock) where this packet begins.</param>
    public void Write(float[] samples, int frames, long expectedStart, Stream output)
    {
        long drift = expectedStart - Written;
        int skip = 0;
        if (drift > _tolerance)
        {
            WriteSilence(drift, output);
            InsertedSilence += drift;
        }
        else if (drift < -_tolerance)
        {
            skip = (int)Math.Min(-drift, frames);
            DroppedFrames += skip;
        }

        int keep = frames - skip;
        if (keep <= 0)
            return;
        output.Write(MemoryMarshal.AsBytes(samples.AsSpan(skip * Channels, keep * Channels)));
        Written += keep;
    }

    /// <summary>Fills with silence up to <paramref name="target"/> (no-op if already there).</summary>
    public void PadTo(long target, Stream output)
    {
        if (target > Written)
            WriteSilence(target - Written, output);
    }

    private void WriteSilence(long frames, Stream output)
    {
        long bytes = frames * Channels * sizeof(float);
        while (bytes > 0)
        {
            int n = (int)Math.Min(bytes, _silence.Length);
            output.Write(_silence, 0, n);
            bytes -= n;
        }
        Written += frames;
    }
}
