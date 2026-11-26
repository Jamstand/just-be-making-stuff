using System.Collections.Concurrent;

namespace Recshot.Capture;

/// <summary>A reference-counted raw video frame. Recycled through <see cref="FramePool"/> to keep the GC quiet.</summary>
internal sealed class FrameBuffer
{
    private readonly FramePool _pool;
    private int _refs;

    public byte[] Data { get; }

    internal FrameBuffer(FramePool pool, int size)
    {
        _pool = pool;
        Data = new byte[size];
    }

    internal void ResetRefs() => _refs = 1;

    public void AddRef() => Interlocked.Increment(ref _refs);

    public void Release()
    {
        int left = Interlocked.Decrement(ref _refs);
        if (left == 0)
            _pool.Return(this);
        else if (left < 0)
            Log.Warn("FrameBuffer released too many times");
    }
}

internal sealed class FramePool
{
    private const int MaxIdle = 12;
    private readonly ConcurrentBag<FrameBuffer> _idle = new();

    public int FrameSize { get; }

    public FramePool(int frameSize) => FrameSize = frameSize;

    public FrameBuffer Rent()
    {
        if (!_idle.TryTake(out FrameBuffer? buffer))
            buffer = new FrameBuffer(this, FrameSize);
        buffer.ResetRefs();
        return buffer;
    }

    internal void Return(FrameBuffer buffer)
    {
        if (_idle.Count < MaxIdle)
            _idle.Add(buffer);
    }
}
