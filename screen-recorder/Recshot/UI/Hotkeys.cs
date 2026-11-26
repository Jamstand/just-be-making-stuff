using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using Recshot.Native;

namespace Recshot.UI;

/// <summary>A key plus modifiers, written like "Ctrl+Shift+F9".</summary>
internal sealed record Hotkey(ModifierKeys Modifiers, Key Key)
{
    public override string ToString()
    {
        var parts = new List<string>();
        if (Modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (Modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (Modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (Modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(KeyName(Key));
        return string.Join("+", parts);
    }

    private static string KeyName(Key key) => key switch
    {
        >= Key.D0 and <= Key.D9 => ((int)(key - Key.D0)).ToString(),
        Key.Snapshot => "PrintScreen",
        _ => key.ToString(),
    };

    public static Hotkey? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;
        ModifierKeys mods = ModifierKeys.None;
        Key key = Key.None;
        foreach (string raw in text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl" or "control": mods |= ModifierKeys.Control; break;
                case "alt": mods |= ModifierKeys.Alt; break;
                case "shift": mods |= ModifierKeys.Shift; break;
                case "win" or "windows": mods |= ModifierKeys.Windows; break;
                case "printscreen": key = Key.Snapshot; break;
                default:
                    if (raw.Length == 1 && char.IsDigit(raw[0]))
                        key = Key.D0 + (raw[0] - '0');
                    else if (!Enum.TryParse(raw, true, out key))
                        return null;
                    break;
            }
        }
        return key == Key.None ? null : new Hotkey(mods, key);
    }

    /// <summary>Builds a hotkey from a key press in a capture box. Returns null for lone modifiers.</summary>
    public static Hotkey? FromKeyEvent(KeyEventArgs e)
    {
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
            or Key.LWin or Key.RWin or Key.None or Key.ImeProcessed or Key.DeadCharProcessed)
            return null;
        ModifierKeys mods = Keyboard.Modifiers;
        // Plain letters without a modifier would hijack typing everywhere.
        bool isFunctionKey = key is >= Key.F1 and <= Key.F24 or Key.Snapshot or Key.Pause or Key.Scroll;
        if (mods == ModifierKeys.None && !isFunctionKey)
            return null;
        return new Hotkey(mods, key);
    }
}

/// <summary>System-wide hotkeys via RegisterHotKey, delivered to a window's message loop.</summary>
internal sealed class HotkeyManager : IDisposable
{
    private readonly HwndSource _source;
    private readonly Dictionary<int, Action> _actions = new();

    public HotkeyManager(Window window)
    {
        IntPtr hwnd = new WindowInteropHelper(window).EnsureHandle();
        _source = HwndSource.FromHwnd(hwnd);
        _source.AddHook(WndProc);
    }

    /// <summary>Registers (or re-registers) hotkey <paramref name="id"/>. False if another app already owns it.</summary>
    public bool Register(int id, Hotkey? hotkey, Action action)
    {
        Unregister(id);
        if (hotkey == null)
            return true;
        uint mods = Win32.MOD_NOREPEAT;
        if (hotkey.Modifiers.HasFlag(ModifierKeys.Control)) mods |= Win32.MOD_CONTROL;
        if (hotkey.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= Win32.MOD_ALT;
        if (hotkey.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= Win32.MOD_SHIFT;
        if (hotkey.Modifiers.HasFlag(ModifierKeys.Windows)) mods |= Win32.MOD_WIN;
        uint vk = (uint)KeyInterop.VirtualKeyFromKey(hotkey.Key);
        if (!Win32.RegisterHotKey(_source.Handle, id, mods, vk))
        {
            Log.Warn($"Hotkey {hotkey} is taken by another app");
            return false;
        }
        _actions[id] = action;
        return true;
    }

    public void Unregister(int id)
    {
        if (_actions.Remove(id))
            Win32.UnregisterHotKey(_source.Handle, id);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Win32.WM_HOTKEY && _actions.TryGetValue(wParam.ToInt32(), out Action? action))
        {
            handled = true;
            action();
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        foreach (int id in _actions.Keys.ToList())
            Unregister(id);
        _source.RemoveHook(WndProc);
    }
}
