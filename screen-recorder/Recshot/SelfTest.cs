using System.IO;
using System.Windows;
using Recshot.Capture;
using Recshot.Core;
using Recshot.Encode;

namespace Recshot;

/// <summary>
/// "Recshot.exe --selftest &lt;folder&gt;" runs the real capture → encode path without the UI and writes
/// selftest.log into the folder: a short recording with a pause, a replay-buffer save and a screenshot.
/// Exit code 0 means every step produced a file. Used by CI on a Windows runner; also handy for support.
/// </summary>
internal static class SelfTest
{
    public static async Task<int> RunAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        string logPath = Path.Combine(folder, "selftest.log");
        var lines = new List<string>();
        int failures = 0;

        void Note(string line)
        {
            lines.Add(line);
            Log.Info("selftest: " + line);
            File.WriteAllLines(logPath, lines);
        }

        void Result(bool ok, string step, string detail)
        {
            Note($"{(ok ? "PASS" : "FAIL")}  {step}: {detail}");
            if (!ok)
                failures++;
        }

        try
        {
            Note($"Windows {Environment.OSVersion.Version}, capture supported: {ScreenCapture.IsSupported}");
            string? ffmpeg = Ffmpeg.Locate();
            Result(ffmpeg != null, "ffmpeg", ffmpeg ?? "not found");
            if (ffmpeg == null)
                return 1;

            List<EncoderInfo> encoders = await EncoderCatalog.ProbeAsync(ffmpeg);
            EncoderInfo encoder = EncoderCatalog.PickDefault(encoders);
            Result(encoders.Count > 0, "encoders", string.Join(", ", encoders.Select(e => e.Id)) + $" → using {encoder.Id}");

            DisplayInfo display = ScreenInfo.GetDisplays().First(d => d.IsPrimary);
            Note($"display: {display.Label}");

            // System audio if this machine has an output device (CI runners usually don't).
            AudioOptions? systemAudio = null;
            try
            {
                if (Audio.AudioCaptureSource.ListDevices(output: true).Count > 0)
                    systemAudio = new AudioOptions(null, 1f);
            }
            catch
            {
            }
            Note($"system audio: {(systemAudio != null ? "yes" : "no device")}");

            var cfg = new PipelineConfig(
                new CaptureTarget(SourceKind.Display, display.Handle, display.Bounds, IntPtr.Zero, display.Bounds, display.Label),
                Fps: 30, MaxHeight: 720, ShowCursor: true, HighlightClicks: false, Webcam: null,
                SystemAudio: systemAudio, Microphone: null, new EncoderOptions(encoder, QualityPreset.Medium));

            var engine = new RecorderEngine(Application.Current.Dispatcher) { FfmpegPath = ffmpeg };
            engine.ErrorOccurred += msg => Note("engine error: " + msg);
            engine.Notice += msg => Note("engine notice: " + msg);

            // A window that changes every frame, so the capture has something moving to encode.
            var animated = new Window
            {
                Width = 360, Height = 200, Left = display.Bounds.Left + 40, Top = display.Bounds.Top + 40,
                WindowStyle = WindowStyle.ToolWindow, Topmost = true, Title = "Recshot self-test",
            };
            var label = new System.Windows.Controls.TextBlock { FontSize = 40, Margin = new Thickness(20) };
            animated.Content = label;
            animated.Show();
            var ticker = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
            int n = 0;
            ticker.Tick += (_, _) => label.Text = $"frame {n++}";
            ticker.Start();

            // 1) Recording with a pause in the middle: ~4 s of content expected.
            await engine.StartRecordingAsync(cfg, folder, asMp4: true);
            Note($"recording at {engine.ActiveOutputSize}, pixel format {engine.Pipeline?.Video.PixelFormat}, GPU {engine.Pipeline?.Gpu.AdapterName}");
            await Task.Delay(2000);
            engine.TogglePause();
            await Task.Delay(1500);
            engine.TogglePause();
            await Task.Delay(2000);
            string? recording = await engine.StopRecordingAsync();
            Result(recording != null && File.Exists(recording) && new FileInfo(recording).Length > 10_000,
                "recording", recording != null ? $"{recording} ({new FileInfo(recording).Length / 1024} KB)" : "no file");

            // 2) Replay buffer: run 7 s, save the last 5 s.
            await engine.StartReplayAsync(cfg, 5);
            await Task.Delay(7000);
            string replay = await engine.SaveReplayAsync(folder);
            Result(File.Exists(replay) && new FileInfo(replay).Length > 10_000, "replay", $"{replay} ({new FileInfo(replay).Length / 1024} KB)");
            await engine.StopReplayAsync();

            // 3) Screenshot of the whole primary display.
            var shot = ScreenGrabber.CaptureScreenRect(display.Bounds);
            string png = await ScreenGrabber.SavePngAsync(shot, folder);
            Result(File.Exists(png), "screenshot", $"{png} ({shot.PixelWidth}x{shot.PixelHeight})");

            // 4) Window screenshot via Windows.Graphics.Capture.
            try
            {
                var handle = new System.Windows.Interop.WindowInteropHelper(animated).Handle;
                var windowShot = await ScreenGrabber.CaptureWindowAsync(handle);
                Result(windowShot.PixelWidth > 0, "window screenshot", $"{windowShot.PixelWidth}x{windowShot.PixelHeight}");
            }
            catch (Exception ex)
            {
                Result(false, "window screenshot", ex.Message);
            }

            // 5) New UI: overlay with tiles (focus triggers the hover animation) and the recording HUD.
            try
            {
                var host = new StubHost();
                var overlay = new UI.OverlayWindow(host, display);
                overlay.Show();
                await Task.Delay(800);
                var tile = FindTiles(overlay).FirstOrDefault();
                tile?.Focus();
                await Task.Delay(600);
                overlay.Refresh();
                await Task.Delay(300);
                overlay.CloseAnimated();
                var hud = new UI.RecordingHud();
                hud.Show();
                hud.Update(TimeSpan.FromSeconds(42), paused: false, micOn: true, micMuted: true);
                await Task.Delay(500);
                hud.Update(TimeSpan.FromSeconds(43), paused: true, micOn: true, micMuted: false);
                hud.Close();
                Result(tile != null, "overlay + HUD", tile != null ? "opened, animated and closed" : "no tiles found");
            }
            catch (Exception ex)
            {
                Result(false, "overlay + HUD", ex.ToString());
            }

            ticker.Stop();
            animated.Close();
            await engine.ShutdownAsync();
        }
        catch (Exception ex)
        {
            Result(false, "exception", ex.ToString());
        }

        Note(failures == 0 ? "ALL PASSED" : $"{failures} FAILED");
        return failures == 0 ? 0 : 1;
    }

    private static IEnumerable<System.Windows.Controls.Button> FindTiles(DependencyObject root)
    {
        int n = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
        for (int i = 0; i < n; i++)
        {
            DependencyObject child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            if (child is System.Windows.Controls.Button b)
                yield return b;
            foreach (var nested in FindTiles(child))
                yield return nested;
        }
    }

    private sealed class StubHost : UI.IOverlayHost
    {
        public bool IsRecording => true;
        public bool IsPaused => false;
        public bool IsReplayRunning => true;
        public bool MicEnabled => true;
        public bool MicMuted => false;
        public bool SystemEnabled => true;
        public int SystemVolume { get; set; } = 100;
        public int MicVolume { get; set; } = 100;
        public float SystemLevel => 0.3f;
        public float MicLevel => 0.5f;
        public TimeSpan Elapsed => TimeSpan.FromSeconds(12);
        public AppSettings Settings { get; } = new();
        public string? FfmpegPath => Ffmpeg.Locate();
        public void ToggleRecord() { }
        public void TogglePauseRecording() { }
        public void SaveReplay() { }
        public void ToggleReplay() { }
        public void Screenshot() { }
        public void ToggleMicMute() { }
        public void OpenSettings() { }
    }
}
