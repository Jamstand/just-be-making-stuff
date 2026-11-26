using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Recshot.Native;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace Recshot.Capture;

/// <summary>Still screenshots: GDI for screen areas (instant, used for the frozen region picker) and WGC for windows.</summary>
internal static class ScreenGrabber
{
    /// <summary>Grabs a rectangle of the desktop at full physical resolution. Must run on the UI thread or any STA.</summary>
    public static BitmapSource CaptureScreenRect(RECT r)
    {
        int w = r.Width, h = r.Height;
        IntPtr screen = Win32.GetDC(IntPtr.Zero);
        IntPtr mem = Win32.CreateCompatibleDC(screen);
        var header = new BITMAPINFOHEADER
        {
            biSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<BITMAPINFOHEADER>(),
            biWidth = w,
            biHeight = -h, // top-down
            biPlanes = 1,
            biBitCount = 32,
        };
        IntPtr dib = Win32.CreateDIBSection(mem, ref header, 0, out IntPtr bits, IntPtr.Zero, 0);
        IntPtr old = Win32.SelectObject(mem, dib);
        try
        {
            Win32.BitBlt(mem, 0, 0, w, h, screen, r.Left, r.Top, Win32.SRCCOPY | Win32.CAPTUREBLT);
            var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr32, null, bits, w * h * 4, w * 4);
            bmp.Freeze();
            return bmp;
        }
        finally
        {
            Win32.SelectObject(mem, old);
            Win32.DeleteObject(dib);
            Win32.DeleteDC(mem);
            Win32.ReleaseDC(IntPtr.Zero, screen);
        }
    }

    /// <summary>One frame of a window via Windows.Graphics.Capture: works even if it's partly covered.</summary>
    public static async Task<BitmapSource> CaptureWindowAsync(IntPtr hwnd)
    {
        if (Win32.IsIconic(hwnd))
            throw new InvalidOperationException("That window is minimised. Restore it first.");

        return await Task.Run(async () =>
        {
            using var gpu = new GpuDevice();
            using var capture = ScreenCapture.ForWindow(gpu, hwnd, showCursor: false);
            var tcs = new TaskCompletionSource<BitmapSource>(TaskCreationOptions.RunContinuationsAsynchronously);

            capture.FrameArrived += (texture, contentW, contentH) =>
            {
                if (tcs.Task.IsCompleted)
                    return;
                try
                {
                    tcs.TrySetResult(ReadTexture(gpu, texture, contentW, contentH));
                }
                catch (Exception ex)
                {
                    tcs.TrySetException(ex);
                }
            };
            capture.Start();

            Task finished = await Task.WhenAny(tcs.Task, Task.Delay(3000));
            if (finished != tcs.Task)
                throw new TimeoutException("The window didn't produce a frame. Is it visible?");
            return await tcs.Task;
        });
    }

    // Called with the GPU lock held.
    private static unsafe BitmapSource ReadTexture(GpuDevice gpu, ID3D11Texture2D texture, int contentW, int contentH)
    {
        Texture2DDescription desc = texture.Description;
        int w = Math.Min(contentW, (int)desc.Width), h = Math.Min(contentH, (int)desc.Height);
        using ID3D11Texture2D staging = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w,
            Height = (uint)h,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read,
        });
        gpu.Context.CopySubresourceRegion(staging, 0, 0, 0, 0, texture, 0, new Box(0, 0, 0, w, h, 1));
        MappedSubresource map = gpu.Context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            var pixels = new byte[w * h * 4];
            fixed (byte* dst = pixels)
            {
                for (int y = 0; y < h; y++)
                    Buffer.MemoryCopy((byte*)map.DataPointer + (long)y * map.RowPitch, dst + (long)y * w * 4, w * 4, w * 4);
            }
            var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr32, null, pixels, w * 4);
            bmp.Freeze();
            return bmp;
        }
        finally
        {
            gpu.Context.Unmap(staging, 0);
        }
    }

    public static BitmapSource Crop(BitmapSource source, Int32Rect rect)
    {
        var cropped = new CroppedBitmap(source, rect);
        cropped.Freeze();
        return cropped;
    }

    /// <summary>Saves a PNG (lossless, full resolution) and returns its path.</summary>
    public static async Task<string> SavePngAsync(BitmapSource image, string folder)
    {
        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, $"Screenshot {DateTime.Now:yyyy-MM-dd HH-mm-ss}.png");
        for (int i = 2; File.Exists(path); i++)
            path = Path.Combine(folder, $"Screenshot {DateTime.Now:yyyy-MM-dd HH-mm-ss} ({i}).png");

        await Task.Run(() =>
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using var stream = File.Create(path);
            encoder.Save(stream);
        });
        return path;
    }
}
