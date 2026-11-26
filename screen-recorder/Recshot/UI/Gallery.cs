using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Media.Imaging;
using Recshot.Encode;

namespace Recshot.UI;

/// <summary>Finds the newest recordings/screenshots and makes small thumbnails for the overlay.</summary>
internal static class Gallery
{
    public sealed record Item(string Path, bool IsVideo, DateTime When);

    private static readonly string ThumbDir = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Recshot", "thumbs");

    public static List<Item> Recent(string videoFolder, string screenshotFolder, int count, string? exclude)
    {
        var items = new List<Item>();
        void Add(string folder, string[] patterns, bool video)
        {
            try
            {
                if (!Directory.Exists(folder))
                    return;
                foreach (string pattern in patterns)
                    foreach (string f in Directory.EnumerateFiles(folder, pattern))
                        if (!string.Equals(f, exclude, StringComparison.OrdinalIgnoreCase))
                            items.Add(new Item(f, video, File.GetLastWriteTime(f)));
            }
            catch
            {
            }
        }
        Add(videoFolder, ["*.mp4", "*.mkv"], true);
        if (!string.Equals(videoFolder, screenshotFolder, StringComparison.OrdinalIgnoreCase))
            Add(screenshotFolder, ["*.png"], false);
        else
            Add(screenshotFolder, ["*.png"], false);
        return items.OrderByDescending(i => i.When).Take(count).ToList();
    }

    /// <summary>A ~320px wide thumbnail, or null. Video frames come from FFmpeg and are cached.</summary>
    public static async Task<BitmapSource?> ThumbnailAsync(Item item, string? ffmpeg)
    {
        try
        {
            string source = item.Path;
            if (item.IsVideo)
            {
                if (ffmpeg == null)
                    return null;
                Directory.CreateDirectory(ThumbDir);
                string key = Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(item.Path + item.When.Ticks)))[..16];
                string thumb = System.IO.Path.Combine(ThumbDir, key + ".jpg");
                if (!File.Exists(thumb))
                {
                    var (code, _) = await Ffmpeg.RunAsync(ffmpeg,
                        ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", "1", "-i", item.Path,
                         "-frames:v", "1", "-vf", "scale=320:-2", thumb], TimeSpan.FromSeconds(15));
                    if (code != 0 || !File.Exists(thumb))
                    {
                        // Very short clips: take the first frame instead.
                        await Ffmpeg.RunAsync(ffmpeg,
                            ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", item.Path,
                             "-frames:v", "1", "-vf", "scale=320:-2", thumb], TimeSpan.FromSeconds(15));
                    }
                    if (!File.Exists(thumb))
                        return null;
                }
                source = thumb;
            }

            return await Task.Run(() =>
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.UriSource = new Uri(source);
                bmp.DecodePixelWidth = 320;
                bmp.CacheOption = BitmapCacheOption.OnLoad; // don't keep the file locked
                bmp.CreateOptions = BitmapCreateOptions.IgnoreImageCache;
                bmp.EndInit();
                bmp.Freeze();
                return (BitmapSource)bmp;
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"Thumbnail failed for {item.Path}: {ex.Message}");
            return null;
        }
    }

    public static string Describe(Item item)
    {
        TimeSpan ago = DateTime.Now - item.When;
        string when = ago.TotalMinutes < 1 ? "just now"
            : ago.TotalHours < 1 ? $"{(int)ago.TotalMinutes} min ago"
            : ago.TotalDays < 1 ? $"{(int)ago.TotalHours} h ago"
            : item.When.ToString("d MMM");
        string kind = item.IsVideo
            ? (System.IO.Path.GetFileName(item.Path).StartsWith("Replay", StringComparison.OrdinalIgnoreCase) ? "Replay" : "Recording")
            : "Screenshot";
        return $"{kind} · {when}";
    }
}
