package tv.glasshome.launcher;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Self-update: reads a small version file from the project's GitHub
 * repository, and if it names a newer build, downloads that build and hands
 * it to Android's installer. Android only accepts it if it is signed with the
 * same key as the copy already installed, and asks the viewer to confirm.
 */
final class Updater {

    private Updater() {
    }

    /** Written by build.sh next to the APK every time a build is made. */
    static final String VERSION_URL = "https://raw.githubusercontent.com/Jamstand/"
            + "just-be-making-stuff/claude/nifty-knuth-b9brge/google-tv-debloat/version.json";

    /** The action on the intent Android sends back with the result of an install. */
    static final String ACTION_INSTALL_STATUS = "tv.glasshome.launcher.INSTALL_STATUS";

    private static final int TIMEOUT_MS = 15000;
    private static final long MIN_APK_BYTES = 10 * 1024L;
    private static final long MAX_APK_BYTES = 50 * 1024 * 1024L;

    static final class Release {
        int versionCode;
        String versionName = "";
        String apkUrl = "";
        String notes = "";
    }

    static int installedCode(Context context) {
        try {
            PackageInfo info = context.getPackageManager()
                    .getPackageInfo(context.getPackageName(), 0);
            return (int) info.getLongVersionCode();
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            return 0;
        }
    }

    static String installedName(Context context) {
        try {
            String name = context.getPackageManager()
                    .getPackageInfo(context.getPackageName(), 0).versionName;
            return name == null ? "" : name;
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            return "";
        }
    }

    /** Reads the newest published version. Throws with a message fit to show on screen. */
    static Release latest() throws IOException, JSONException {
        JSONObject json = new JSONObject(Videos.get(VERSION_URL, null));
        Release release = new Release();
        release.versionCode = json.getInt("versionCode");
        release.versionName = json.optString("versionName");
        release.apkUrl = json.getString("apk");
        release.notes = json.optString("notes");
        if (!release.apkUrl.startsWith("https://")) {
            throw new IOException("The update address is not a secure one");
        }
        return release;
    }

    /** Downloads the build into the app's private cache folder. */
    static File download(Context context, Release release) throws IOException {
        File target = new File(context.getCacheDir(), "update.apk");
        HttpURLConnection connection =
                (HttpURLConnection) new URL(release.apkUrl).openConnection();
        try {
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            int status = connection.getResponseCode();
            if (status != 200) {
                throw new IOException("Download failed (error " + status + ")");
            }
            long total = 0;
            try (InputStream in = connection.getInputStream();
                    OutputStream out = new FileOutputStream(target)) {
                byte[] chunk = new byte[16384];
                int count;
                while ((count = in.read(chunk)) != -1) {
                    total += count;
                    if (total > MAX_APK_BYTES) {
                        throw new IOException("The download is far too large to be the app");
                    }
                    out.write(chunk, 0, count);
                }
            }
            if (total < MIN_APK_BYTES) {
                throw new IOException("The download is too small to be the app");
            }
            return target;
        } finally {
            connection.disconnect();
        }
    }

    /**
     * Hands the downloaded build to Android's installer. The result comes
     * back to {@code activity} as an intent with ACTION_INSTALL_STATUS.
     */
    static void install(Activity activity, File apk) throws IOException {
        PackageInstaller installer = activity.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(activity.getPackageName());
        int sessionId = installer.createSession(params);
        try (PackageInstaller.Session session = installer.openSession(sessionId)) {
            try (InputStream in = new FileInputStream(apk);
                    OutputStream out = session.openWrite("glasshome", 0, apk.length())) {
                byte[] chunk = new byte[16384];
                int count;
                while ((count = in.read(chunk)) != -1) {
                    out.write(chunk, 0, count);
                }
                session.fsync(out);
            }
            Intent callback = new Intent(activity, activity.getClass());
            callback.setAction(ACTION_INSTALL_STATUS);
            // The system fills in the result, so the intent has to be mutable.
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                flags |= PendingIntent.FLAG_MUTABLE;
            }
            PendingIntent result = PendingIntent.getActivity(activity, sessionId, callback, flags);
            session.commit(result.getIntentSender());
        } catch (RuntimeException e) {
            throw new IOException("The installer refused the update: " + e.getMessage());
        }
    }
}
