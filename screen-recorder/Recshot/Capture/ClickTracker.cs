using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Recshot.Native;

namespace Recshot.Capture;

/// <summary>
/// Watches mouse clicks system-wide with a low-level hook so they can be drawn as rings in the video.
/// The hook lives on the UI thread (it needs a message loop) and only stores timestamps and positions.
/// </summary>
internal sealed class ClickTracker : IDisposable
{
    public readonly record struct Click(long Timestamp, int X, int Y, bool IsRight);

    private const int MaxClicks = 32;
    private readonly Dispatcher _dispatcher;
    private readonly List<Click> _clicks = new();
    private readonly object _gate = new();
    private readonly Win32.LowLevelMouseProc _proc;
    private IntPtr _hook;

    public ClickTracker(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        _proc = HookProc;
        _dispatcher.Invoke(() =>
        {
            _hook = Win32.SetWindowsHookEx(Win32.WH_MOUSE_LL, _proc, Win32.GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
                Log.Warn($"Mouse hook failed: {Marshal.GetLastWin32Error()}");
        });
    }

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg is Win32.WM_LBUTTONDOWN or Win32.WM_RBUTTONDOWN or Win32.WM_MBUTTONDOWN)
            {
                var data = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
                lock (_gate)
                {
                    if (_clicks.Count >= MaxClicks)
                        _clicks.RemoveAt(0);
                    _clicks.Add(new Click(Stopwatch.GetTimestamp(), data.pt.X, data.pt.Y, msg == Win32.WM_RBUTTONDOWN));
                }
            }
        }
        return Win32.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    /// <summary>Copies clicks younger than <paramref name="maxAgeSeconds"/> into <paramref name="into"/>.</summary>
    public void GetRecent(double maxAgeSeconds, List<Click> into)
    {
        into.Clear();
        long cutoff = Stopwatch.GetTimestamp() - (long)(maxAgeSeconds * Stopwatch.Frequency);
        lock (_gate)
        {
            _clicks.RemoveAll(c => c.Timestamp < cutoff);
            into.AddRange(_clicks);
        }
    }

    public void Dispose()
    {
        if (_hook == IntPtr.Zero)
            return;
        IntPtr hook = _hook;
        _hook = IntPtr.Zero;
        try
        {
            _dispatcher.Invoke(() => Win32.UnhookWindowsHookEx(hook));
        }
        catch (Exception ex)
        {
            Log.Warn($"Unhook failed: {ex.Message}");
        }
    }
}
