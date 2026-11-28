package tv.glasshome.launcher;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.provider.Settings;
import android.text.TextUtils;

import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

/**
 * The TV settings Glass Home can change by itself: the ad muter, the
 * screensaver, ad-blocking DNS and animation speed. All of them need the
 * WRITE_SECURE_SETTINGS permission, which only a computer can grant over ADB
 * (the PC tool does it in option 5). Used by the Customize screen and the
 * phone control page.
 */
final class SystemSettings {

    private SystemSettings() {
    }

    static final String AD_MUTER =
            "tv.glasshome.launcher/tv.glasshome.launcher.AdMuteService";
    static final String SCREENSAVER =
            "tv.glasshome.launcher/tv.glasshome.launcher.ClockDream";
    /** AdGuard DNS: a free public service that refuses known ad and tracker addresses. */
    static final String ADBLOCK_HOST = "dns.adguard-dns.com";

    private static final String PREF_SCREENSAVER_BEFORE = "screensaver_before";
    private static final String[] ANIMATION_SCALES = {
        "window_animation_scale", "transition_animation_scale", "animator_duration_scale"};

    static boolean canWrite(Context context) {
        return context.checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS")
                == PackageManager.PERMISSION_GRANTED;
    }

    // --- Reading and writing ---

    static String secure(Context context, String name) {
        try {
            String value = Settings.Secure.getString(context.getContentResolver(), name);
            return value == null ? "" : value;
        } catch (RuntimeException e) {
            return "";
        }
    }

    static boolean putSecure(Context context, String name, String value) {
        try {
            return Settings.Secure.putString(context.getContentResolver(), name, value);
        } catch (RuntimeException e) {
            return false; // Permission not granted yet.
        }
    }

    static String global(Context context, String name) {
        try {
            String value = Settings.Global.getString(context.getContentResolver(), name);
            return value == null ? "" : value;
        } catch (RuntimeException e) {
            return "";
        }
    }

    static boolean putGlobal(Context context, String name, String value) {
        try {
            return Settings.Global.putString(context.getContentResolver(), name, value);
        } catch (RuntimeException e) {
            return false;
        }
    }

    private static boolean sameComponent(String a, String b) {
        ComponentName first = a == null ? null : ComponentName.unflattenFromString(a.trim());
        ComponentName second = b == null ? null : ComponentName.unflattenFromString(b.trim());
        return first != null && first.equals(second);
    }

    // --- Ad muter ---

    static boolean isAdMuterOn(Context context) {
        for (String service : secure(context, "enabled_accessibility_services").split(":")) {
            if (sameComponent(service, AD_MUTER)) {
                return true;
            }
        }
        return false;
    }

    static boolean setAdMuter(Context context, boolean on) {
        List<String> services = new ArrayList<>();
        for (String service : secure(context, "enabled_accessibility_services").split(":")) {
            if (!service.isEmpty() && !sameComponent(service, AD_MUTER)) {
                services.add(service);
            }
        }
        if (on) {
            services.add(AD_MUTER);
        }
        if (!putSecure(context, "enabled_accessibility_services", TextUtils.join(":", services))) {
            return false;
        }
        return !on || putSecure(context, "accessibility_enabled", "1");
    }

    // --- Screensaver ---

    static boolean isScreensaverOn(Context context) {
        return sameComponent(secure(context, "screensaver_components"), SCREENSAVER);
    }

    static boolean setScreensaver(Context context, Apps.Prefs prefs, boolean on) {
        if (on == isScreensaverOn(context)) {
            return true;
        }
        if (!on) {
            // Put back whatever was there before this was turned on.
            String before = prefs.text(PREF_SCREENSAVER_BEFORE);
            return putSecure(context, "screensaver_components", before.isEmpty() ? null : before);
        }
        String before = secure(context, "screensaver_components");
        if (!putSecure(context, "screensaver_components", SCREENSAVER)) {
            return false;
        }
        prefs.saveText(PREF_SCREENSAVER_BEFORE, before);
        return putSecure(context, "screensaver_enabled", "1");
    }

    // --- Ad-blocking DNS ---

    static boolean isAdBlockOn(Context context) {
        return "hostname".equals(global(context, "private_dns_mode"))
                && ADBLOCK_HOST.equals(global(context, "private_dns_specifier"));
    }

    static boolean setAdBlock(Context context, boolean on) {
        if (on) {
            return putGlobal(context, "private_dns_specifier", ADBLOCK_HOST)
                    && putGlobal(context, "private_dns_mode", "hostname");
        }
        // "opportunistic" is Android's normal automatic setting.
        return putGlobal(context, "private_dns_mode", "opportunistic")
                && putGlobal(context, "private_dns_specifier", null);
    }

    /** True if the TV can reach the internet right now. Slow: call off the main thread. */
    static boolean online() {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection)
                    new URL("https://www.google.com/generate_204").openConnection();
            connection.setConnectTimeout(5000);
            connection.setReadTimeout(5000);
            connection.setUseCaches(false);
            return connection.getResponseCode() == 204;
        } catch (IOException | RuntimeException e) {
            return false;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    // --- Animation speed ---

    /** "1" is normal, "0.5" fast, "0" off. */
    static String animationScale(Context context) {
        String value = global(context, "window_animation_scale");
        return value.isEmpty() ? "1" : value;
    }

    static boolean setAnimationScale(Context context, String value) {
        for (String name : ANIMATION_SCALES) {
            if (!putGlobal(context, name, value)) {
                return false;
            }
        }
        return true;
    }
}
