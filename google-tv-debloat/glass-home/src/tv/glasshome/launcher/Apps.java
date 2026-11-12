package tv.glasshome.launcher;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Reads the installed apps and remembers the user's choices. */
final class Apps {

    private Apps() {
    }

    /** One launchable app. */
    static final class Entry {
        ComponentName component;
        String key;
        String label;
        Drawable banner;
        Drawable icon;
        boolean leanback;

        String packageName() {
            return component.getPackageName();
        }
    }

    /** Apps people usually want up front, used only to pick first-run favorites. */
    private static final String[] PREFERRED = {
        "com.google.android.youtube.tv",
        "com.netflix.ninja",
        "com.amazon.amazonvideo.livingroom",
        "com.disney.disneyplus",
        "com.hulu.livingroomplus",
        "com.wbd.stream",
        "com.apple.atve.androidtv.appletv",
        "com.spotify.tv.android",
        "com.plexapp.android",
        "com.google.android.youtube.tvmusic",
    };

    private static final int DEFAULT_FAVORITE_COUNT = 6;

    /** Every app with a TV launcher entry, then phone-style apps that lack one. Sorted by name. */
    static List<Entry> load(Context context) {
        PackageManager pm = context.getPackageManager();
        List<Entry> result = new ArrayList<>();
        Set<String> seenPackages = new HashSet<>();
        seenPackages.add(context.getPackageName());

        addMatches(pm, Intent.CATEGORY_LEANBACK_LAUNCHER, true, result, seenPackages);
        addMatches(pm, Intent.CATEGORY_LAUNCHER, false, result, seenPackages);

        Collections.sort(result, (a, b) -> a.label.compareToIgnoreCase(b.label));
        return result;
    }

    private static void addMatches(PackageManager pm, String category, boolean leanback,
            List<Entry> out, Set<String> seenPackages) {
        Intent query = new Intent(Intent.ACTION_MAIN);
        query.addCategory(category);
        List<ResolveInfo> matches;
        try {
            matches = pm.queryIntentActivities(query, 0);
        } catch (RuntimeException e) {
            return;
        }
        Set<String> addedNow = new HashSet<>();
        for (ResolveInfo info : matches) {
            ActivityInfo activity = info.activityInfo;
            if (activity == null || seenPackages.contains(activity.packageName)) {
                continue;
            }
            // One tile per app, even if it declares several launcher activities.
            if (!addedNow.add(activity.packageName)) {
                continue;
            }
            Entry entry = new Entry();
            entry.component = new ComponentName(activity.packageName, activity.name);
            entry.key = entry.component.flattenToString();
            entry.leanback = leanback;
            try {
                CharSequence label = info.loadLabel(pm);
                entry.label = label != null ? label.toString() : activity.packageName;
            } catch (RuntimeException e) {
                entry.label = activity.packageName;
            }
            try {
                entry.banner = activity.loadBanner(pm);
            } catch (RuntimeException | OutOfMemoryError e) {
                entry.banner = null;
            }
            if (entry.banner == null) {
                try {
                    entry.icon = info.loadIcon(pm);
                } catch (RuntimeException | OutOfMemoryError e) {
                    entry.icon = null;
                }
            }
            out.add(entry);
        }
        seenPackages.addAll(addedNow);
    }

    static Entry find(List<Entry> apps, String key) {
        for (Entry entry : apps) {
            if (entry.key.equals(key)) {
                return entry;
            }
        }
        return null;
    }

    /** First-run favorites: well-known streaming apps first, then whatever else is installed. */
    static List<String> defaultFavorites(List<Entry> apps) {
        List<String> favorites = new ArrayList<>();
        for (String preferred : PREFERRED) {
            for (Entry entry : apps) {
                if (entry.packageName().equals(preferred) && favorites.size() < DEFAULT_FAVORITE_COUNT) {
                    favorites.add(entry.key);
                }
            }
        }
        for (Entry entry : apps) {
            if (favorites.size() >= DEFAULT_FAVORITE_COUNT) {
                break;
            }
            if (!favorites.contains(entry.key) && entry.leanback) {
                favorites.add(entry.key);
            }
        }
        return favorites;
    }

    /** Saved settings: favorites order, background style, motion on or off. */
    static final class Prefs {
        private static final String KEY_FAVORITES = "favorites";
        private static final String KEY_PALETTE = "palette";
        private static final String KEY_MOTION = "motion";

        private final SharedPreferences store;

        Prefs(Context context) {
            store = context.getSharedPreferences("glass_home", Context.MODE_PRIVATE);
        }

        boolean hasFavorites() {
            return store.contains(KEY_FAVORITES);
        }

        List<String> favorites() {
            List<String> list = new ArrayList<>();
            String raw = store.getString(KEY_FAVORITES, "");
            if (raw == null || raw.isEmpty()) {
                return list;
            }
            for (String key : raw.split("\n")) {
                if (!key.isEmpty() && !list.contains(key)) {
                    list.add(key);
                }
            }
            return list;
        }

        void saveFavorites(List<String> keys) {
            StringBuilder joined = new StringBuilder();
            for (String key : keys) {
                if (joined.length() > 0) {
                    joined.append('\n');
                }
                joined.append(key);
            }
            store.edit().putString(KEY_FAVORITES, joined.toString()).apply();
        }

        int palette() {
            return store.getInt(KEY_PALETTE, 0);
        }

        void savePalette(int index) {
            store.edit().putInt(KEY_PALETTE, index).apply();
        }

        boolean motion() {
            return store.getBoolean(KEY_MOTION, true);
        }

        void saveMotion(boolean enabled) {
            store.edit().putBoolean(KEY_MOTION, enabled).apply();
        }
    }
}
