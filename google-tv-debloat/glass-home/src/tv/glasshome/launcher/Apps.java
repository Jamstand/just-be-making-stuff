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

    static final String DISNEY_PACKAGE = "com.disney.disneyplus";
    static final String HULU_PACKAGE = "com.hulu.livingroomplus";

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

    /**
     * A quick fingerprint of which apps are installed. Lets the launcher skip
     * the slow part (loading every banner) when nothing has changed.
     */
    static String fingerprint(Context context) {
        PackageManager pm = context.getPackageManager();
        List<String> names = new ArrayList<>();
        for (String category : new String[] {
                Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER}) {
            Intent query = new Intent(Intent.ACTION_MAIN);
            query.addCategory(category);
            try {
                for (ResolveInfo info : pm.queryIntentActivities(query, 0)) {
                    if (info.activityInfo != null) {
                        names.add(category.length() + info.activityInfo.packageName
                                + "/" + info.activityInfo.name);
                    }
                }
            } catch (RuntimeException e) {
                return "";
            }
        }
        Collections.sort(names);
        return names.toString();
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

    /** Saved settings: favorites, recents, background style, and the YouTube rows. */
    static final class Prefs {
        private static final String KEY_FAVORITES = "favorites";
        private static final String KEY_PALETTE = "palette";
        private static final String KEY_MOTION = "motion";
        private static final String KEY_RECENTS = "recents";
        private static final String KEY_API_KEY = "youtube_api_key";
        private static final String KEY_CHANNELS = "watched_channels";
        private static final String KEY_VIDEO_CACHE = "video_cache";
        private static final String KEY_VIDEO_CACHE_TIME = "video_cache_time";
        private static final int MAX_RECENTS = 10;
        private static final int MAX_CHANNELS = 8;

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

        // --- Plain named values, for the newer features ---

        String text(String name) {
            String value = store.getString(name, "");
            return value == null ? "" : value;
        }

        void saveText(String name, String value) {
            store.edit().putString(name, value).apply();
        }

        long time(String name) {
            return store.getLong(name, 0L);
        }

        void saveTime(String name, long value) {
            store.edit().putLong(name, value).apply();
        }

        boolean flag(String name) {
            return store.getBoolean(name, false);
        }

        void saveFlag(String name, boolean value) {
            store.edit().putBoolean(name, value).apply();
        }

        // --- Recently opened apps, newest first ---

        List<String> recents() {
            return readList(KEY_RECENTS);
        }

        void pushRecent(String key) {
            pushFront(KEY_RECENTS, key, MAX_RECENTS);
        }

        // --- YouTube rows ---

        String apiKey() {
            String key = store.getString(KEY_API_KEY, "");
            return key == null ? "" : key;
        }

        void saveApiKey(String key) {
            store.edit().putString(KEY_API_KEY, key).remove(KEY_VIDEO_CACHE)
                    .remove(KEY_VIDEO_CACHE_TIME).apply();
        }

        /** Channels whose videos were opened from the home screen, newest first. */
        List<String> watchedChannels() {
            return readList(KEY_CHANNELS);
        }

        void pushWatchedChannel(String channelId) {
            pushFront(KEY_CHANNELS, channelId, MAX_CHANNELS);
        }

        String videoCache() {
            return store.getString(KEY_VIDEO_CACHE, "");
        }

        long videoCacheTime() {
            return store.getLong(KEY_VIDEO_CACHE_TIME, 0L);
        }

        void saveVideoCache(String json) {
            store.edit().putString(KEY_VIDEO_CACHE, json)
                    .putLong(KEY_VIDEO_CACHE_TIME, System.currentTimeMillis()).apply();
        }

        private List<String> readList(String name) {
            List<String> list = new ArrayList<>();
            String raw = store.getString(name, "");
            if (raw == null || raw.isEmpty()) {
                return list;
            }
            for (String item : raw.split("\n")) {
                if (!item.isEmpty() && !list.contains(item)) {
                    list.add(item);
                }
            }
            return list;
        }

        private void pushFront(String name, String item, int limit) {
            if (item == null || item.isEmpty()) {
                return;
            }
            List<String> list = readList(name);
            list.remove(item);
            list.add(0, item);
            StringBuilder joined = new StringBuilder();
            for (int i = 0; i < list.size() && i < limit; i++) {
                if (i > 0) {
                    joined.append('\n');
                }
                joined.append(list.get(i));
            }
            store.edit().putString(name, joined.toString()).apply();
        }
    }
}
