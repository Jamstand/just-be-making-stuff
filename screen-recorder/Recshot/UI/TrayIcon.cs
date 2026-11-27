using Forms = System.Windows.Forms;

namespace Recshot.UI;

/// <summary>Notification-area icon with a right-click menu, so Recshot can live in the background.</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.ToolStripMenuItem _record;
    private readonly Forms.ToolStripMenuItem _pause;
    private readonly Forms.ToolStripMenuItem _replay;
    private readonly Forms.ToolStripMenuItem _saveReplay;
    private readonly System.Drawing.Icon _idleIcon;
    private readonly System.Drawing.Icon _recordingIcon;

    public TrayIcon(Action show, Action toggleRecord, Action togglePause, Action toggleReplay, Action saveReplay,
        Action screenshot, Action openVideos, Action quit)
    {
        _idleIcon = LoadAppIcon();
        _recordingIcon = MakeRecordingIcon();

        var menu = new Forms.ContextMenuStrip { Renderer = new Forms.ToolStripProfessionalRenderer(new DarkColors()), ForeColor = System.Drawing.Color.FromArgb(245, 246, 248), ShowImageMargin = false };
        menu.Items.Add("Open Recshot", null, (_, _) => show());
        menu.Items.Add(new Forms.ToolStripSeparator());
        _record = new Forms.ToolStripMenuItem("Start recording", null, (_, _) => toggleRecord());
        _pause = new Forms.ToolStripMenuItem("Pause", null, (_, _) => togglePause()) { Enabled = false };
        _replay = new Forms.ToolStripMenuItem("Replay buffer", null, (_, _) => toggleReplay());
        _saveReplay = new Forms.ToolStripMenuItem("Save replay", null, (_, _) => saveReplay()) { Enabled = false };
        menu.Items.AddRange([_record, _pause, new Forms.ToolStripSeparator(), _replay, _saveReplay, new Forms.ToolStripSeparator()]);
        menu.Items.Add("Screenshot", null, (_, _) => screenshot());
        menu.Items.Add("Open videos folder", null, (_, _) => openVideos());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Recshot", null, (_, _) => quit());
        menu.Items[0].Font = new System.Drawing.Font(menu.Font, System.Drawing.FontStyle.Bold);

        _icon = new Forms.NotifyIcon
        {
            Icon = _idleIcon,
            Text = "Recshot",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
                show();
        };
    }

    private sealed class DarkColors : Forms.ProfessionalColorTable
    {
        private static readonly System.Drawing.Color Bg = System.Drawing.Color.FromArgb(28, 30, 37);
        private static readonly System.Drawing.Color Hover = System.Drawing.Color.FromArgb(48, 51, 61);
        public override System.Drawing.Color ToolStripDropDownBackground => Bg;
        public override System.Drawing.Color MenuBorder => System.Drawing.Color.FromArgb(60, 63, 72);
        public override System.Drawing.Color MenuItemSelected => Hover;
        public override System.Drawing.Color MenuItemBorder => Hover;
        public override System.Drawing.Color SeparatorDark => System.Drawing.Color.FromArgb(60, 63, 72);
        public override System.Drawing.Color SeparatorLight => Bg;
        public override System.Drawing.Color ImageMarginGradientBegin => Bg;
        public override System.Drawing.Color ImageMarginGradientMiddle => Bg;
        public override System.Drawing.Color ImageMarginGradientEnd => Bg;
        public override System.Drawing.Color CheckBackground => Hover;
        public override System.Drawing.Color CheckSelectedBackground => Hover;
    }

    public void Update(bool recording, bool paused, bool replayOn, string tooltip)
    {
        _record.Text = recording ? "Stop recording" : "Start recording";
        _pause.Enabled = recording;
        _pause.Text = paused ? "Resume" : "Pause";
        _replay.Checked = replayOn;
        _saveReplay.Enabled = replayOn;
        _icon.Icon = recording ? _recordingIcon : _idleIcon;
        // NotifyIcon tooltips are limited to 127 characters.
        _icon.Text = tooltip.Length > 127 ? tooltip[..127] : tooltip;
    }

    public void ShowBalloon(string title, string text)
        => _icon.ShowBalloonTip(4000, title, text, Forms.ToolTipIcon.Info);

    private static System.Drawing.Icon LoadAppIcon()
    {
        try
        {
            if (Environment.ProcessPath is { } exe)
                return System.Drawing.Icon.ExtractAssociatedIcon(exe) ?? System.Drawing.SystemIcons.Application;
        }
        catch
        {
        }
        return System.Drawing.SystemIcons.Application;
    }

    /// <summary>A plain red dot, so it's obvious from the taskbar that a recording is running.</summary>
    private static System.Drawing.Icon MakeRecordingIcon()
    {
        using var bmp = new System.Drawing.Bitmap(32, 32);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);
            using var red = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(239, 68, 68));
            g.FillEllipse(red, 3, 3, 26, 26);
            using var ring = new System.Drawing.Pen(System.Drawing.Color.White, 2);
            g.DrawEllipse(ring, 3, 3, 26, 26);
        }
        return System.Drawing.Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
