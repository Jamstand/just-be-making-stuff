using System.Diagnostics;
using System.Text;
using Recshot.Native;

namespace Recshot.Core;

public sealed record DisplayInfo(int Index, IntPtr Handle, string DeviceName, RECT Bounds, bool IsPrimary)
{
    public string Label => $"Display {Index}{(IsPrimary ? " (main)" : "")}  ·  {Bounds.Width} × {Bounds.Height}";
}

public sealed record WindowInfo(IntPtr Handle, string Title, string ProcessName)
{
    public string Label => string.IsNullOrEmpty(ProcessName) ? Title : $"{Title}  ·  {ProcessName}";
}

public static class ScreenInfo
{
    public static List<DisplayInfo> GetDisplays()
    {
        var raw = new List<(IntPtr Handle, string Device, RECT Bounds, bool Primary)>();
        Win32.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var info = new MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFOEX>() };
            if (Win32.GetMonitorInfo(h, ref info))
                raw.Add((h, info.szDevice, info.rcMonitor, (info.dwFlags & Win32.MONITORINFOF_PRIMARY) != 0));
            return true;
        }, IntPtr.Zero);

        // Number displays left-to-right, top-to-bottom, the way people point at them.
        return raw
            .OrderBy(m => m.Bounds.Left).ThenBy(m => m.Bounds.Top)
            .Select((m, i) => new DisplayInfo(i + 1, m.Handle, m.Device, m.Bounds, m.Primary))
            .ToList();
    }

    public static DisplayInfo? DisplayContaining(int x, int y)
        => GetDisplays().FirstOrDefault(d => x >= d.Bounds.Left && x < d.Bounds.Right && y >= d.Bounds.Top && y < d.Bounds.Bottom);

    public static List<WindowInfo> GetWindows(IEnumerable<IntPtr> exclude)
    {
        var excluded = new HashSet<IntPtr>(exclude);
        IntPtr shell = Win32.GetShellWindow();
        int ownPid = Environment.ProcessId;
        var result = new List<WindowInfo>();
        var processNames = new Dictionary<uint, string>();

        Win32.EnumWindows((hwnd, _) =>
        {
            if (hwnd == shell || excluded.Contains(hwnd) || !Win32.IsWindowVisible(hwnd))
                return true;
            if (Win32.GetWindow(hwnd, Win32.GW_OWNER) != IntPtr.Zero)
                return true;
            long ex = Win32.GetWindowLongPtr(hwnd, Win32.GWL_EXSTYLE).ToInt64();
            if ((ex & Win32.WS_EX_TOOLWINDOW) != 0)
                return true;
            if (Win32.IsCloaked(hwnd))
                return true;
            int len = Win32.GetWindowTextLength(hwnd);
            if (len == 0)
                return true;
            var sb = new StringBuilder(len + 1);
            Win32.GetWindowText(hwnd, sb, sb.Capacity);
            string title = sb.ToString().Trim();
            if (title.Length == 0)
                return true;

            Win32.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == ownPid)
                return true;
            if (!processNames.TryGetValue(pid, out string? proc))
            {
                try
                {
                    using var p = Process.GetProcessById((int)pid);
                    proc = p.ProcessName + ".exe";
                }
                catch
                {
                    proc = "";
                }
                processNames[pid] = proc;
            }

            result.Add(new WindowInfo(hwnd, title, proc));
            return true;
        }, IntPtr.Zero);

        return result;
    }
}
