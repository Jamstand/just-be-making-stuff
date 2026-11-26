using System.Windows;
using System.Windows.Threading;
using Recshot.Capture;
using Recshot.Core;

namespace Recshot;

public partial class App : Application
{
    private Mutex? _singleInstance;
    private EventWaitHandle _showSignal = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Error("Unhandled exception", args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Error("Unobserved task exception", args.Exception);
            args.SetObserved();
        };

        int selfTest = Array.IndexOf(e.Args, "--selftest");
        if (selfTest >= 0)
        {
            string folder = selfTest + 1 < e.Args.Length ? e.Args[selfTest + 1] : System.IO.Path.Combine(System.IO.Path.GetTempPath(), "recshot-selftest");
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Dispatcher.InvokeAsync(async () => Shutdown(await SelfTest.RunAsync(folder)));
            return;
        }

        _singleInstance = new Mutex(true, @"Local\Recshot.SingleInstance", out bool isFirst);
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Recshot.Show");
        if (!isFirst)
        {
            // Already running (probably in the tray): bring that one up instead.
            _showSignal.Set();
            Shutdown();
            return;
        }

        Log.Info($"Recshot {typeof(App).Assembly.GetName().Version} starting on {Environment.OSVersion}");

        bool captureSupported;
        try
        {
            captureSupported = ScreenCapture.IsSupported;
        }
        catch
        {
            captureSupported = false;
        }
        if (!captureSupported)
        {
            MessageBox.Show("Recshot needs Windows 10 version 2004 or newer (or Windows 11) for screen capture.",
                "Recshot", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        RecorderEngine.CleanStaleReplayFolders();
        bool background = e.Args.Contains("--background");
        var window = new MainWindow { StartHidden = background };
        if (background)
        {
            window.ShowActivated = false;
            window.WindowState = WindowState.Minimized;
        }
        MainWindow = window;
        window.Show();

        // A second launch signals us to show the window.
        var waiter = new Thread(() =>
        {
            while (_showSignal.WaitOne())
                Dispatcher.BeginInvoke(() => window.ShowFromTray());
        }) { IsBackground = true, Name = "Recshot show signal" };
        waiter.Start();
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Error("UI exception", e.Exception);
        MessageBox.Show($"Something went wrong:\n\n{e.Exception.Message}\n\nDetails were written to {Log.FilePath}",
            "Recshot", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
