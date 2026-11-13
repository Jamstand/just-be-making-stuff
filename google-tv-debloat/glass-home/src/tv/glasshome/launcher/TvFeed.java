package tv.glasshome.launcher;

import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.tv.TvContract;
import android.net.Uri;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Reads what other apps have published to Android TV's shared "TV provider":
 * their continue-watching entries and their recommendation rows. This is the
 * same data the stock home screen shows. It needs the READ_TV_LISTINGS
 * permission, which the viewer grants once.
 */
final class TvFeed {

    private TvFeed() {
    }

    static final String PERMISSION = "android.permission.READ_TV_LISTINGS";

    private static final int MAX_ITEMS = 24;

    /** One thing to watch, published by some app. */
    static final class Item {
        String title = "";
        String subtitle = "";
        String art = "";
        String intentUri = "";
        String packageName = "";
        long engagedAt;
        /** 0 to 100, or -1 when the app did not say how far in the viewer is. */
        int progress = -1;
    }

    static boolean hasPermission(Context context) {
        return context.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED;
    }

    /** Continue-watching entries from every app, most recently watched first. */
    static List<Item> watchNext(Context context) {
        List<Item> items = new ArrayList<>();
        if (!hasPermission(context)) {
            return items;
        }
        String[] columns = {
            TvContract.WatchNextPrograms.COLUMN_PACKAGE_NAME,
            TvContract.WatchNextPrograms.COLUMN_TITLE,
            TvContract.WatchNextPrograms.COLUMN_EPISODE_TITLE,
            TvContract.WatchNextPrograms.COLUMN_POSTER_ART_URI,
            TvContract.WatchNextPrograms.COLUMN_THUMBNAIL_URI,
            TvContract.WatchNextPrograms.COLUMN_INTENT_URI,
            TvContract.WatchNextPrograms.COLUMN_LAST_ENGAGEMENT_TIME_UTC_MILLIS,
            TvContract.WatchNextPrograms.COLUMN_LAST_PLAYBACK_POSITION_MILLIS,
            TvContract.WatchNextPrograms.COLUMN_DURATION_MILLIS,
            TvContract.WatchNextPrograms.COLUMN_BROWSABLE,
        };
        // No selection or sort order: the provider rejects both from ordinary apps.
        try (Cursor cursor = context.getContentResolver().query(
                TvContract.WatchNextPrograms.CONTENT_URI, columns, null, null, null)) {
            if (cursor == null) {
                return items;
            }
            while (cursor.moveToNext()) {
                if (!cursor.isNull(9) && cursor.getInt(9) == 0) {
                    continue; // The app or the viewer has hidden this entry.
                }
                Item item = new Item();
                item.packageName = text(cursor, 0);
                item.title = text(cursor, 1);
                item.subtitle = text(cursor, 2);
                item.art = text(cursor, 3).isEmpty() ? text(cursor, 4) : text(cursor, 3);
                item.intentUri = text(cursor, 5);
                item.engagedAt = cursor.isNull(6) ? 0L : cursor.getLong(6);
                long position = cursor.isNull(7) ? 0L : cursor.getLong(7);
                long duration = cursor.isNull(8) ? 0L : cursor.getLong(8);
                if (duration > 0 && position > 0) {
                    item.progress = (int) Math.max(1, Math.min(100, position * 100 / duration));
                }
                if (!item.title.isEmpty() && !item.packageName.equals(context.getPackageName())) {
                    items.add(item);
                }
            }
        } catch (RuntimeException e) {
            return new ArrayList<>();
        }
        Collections.sort(items, (a, b) -> Long.compare(b.engagedAt, a.engagedAt));
        return items.size() > MAX_ITEMS ? new ArrayList<>(items.subList(0, MAX_ITEMS)) : items;
    }

    /**
     * The recommendations row that a YouTube app (the official one or a
     * third-party player) publishes for its signed-in viewer. Empty if no
     * YouTube app on this TV publishes one.
     */
    static List<Item> youtubeRecommended(Context context) {
        List<Item> none = new ArrayList<>();
        if (!hasPermission(context)) {
            return none;
        }

        // Step 1: find the rows ("channels") that YouTube apps have published.
        Map<Long, String> channelNames = new HashMap<>();
        Map<Long, String> channelPackages = new HashMap<>();
        String[] channelColumns = {
            TvContract.Channels._ID,
            TvContract.Channels.COLUMN_PACKAGE_NAME,
            TvContract.Channels.COLUMN_DISPLAY_NAME,
        };
        try (Cursor cursor = context.getContentResolver().query(
                TvContract.Channels.CONTENT_URI, channelColumns, null, null, null)) {
            if (cursor == null) {
                return none;
            }
            while (cursor.moveToNext()) {
                String packageName = text(cursor, 1);
                if (isYouTubeApp(packageName)) {
                    channelNames.put(cursor.getLong(0), text(cursor, 2));
                    channelPackages.put(cursor.getLong(0), packageName);
                }
            }
        } catch (RuntimeException e) {
            return none;
        }
        if (channelNames.isEmpty()) {
            return none;
        }

        // Step 2: read the videos in those rows.
        Map<Long, List<Item>> byChannel = new HashMap<>();
        String[] columns = {
            TvContract.PreviewPrograms.COLUMN_CHANNEL_ID,
            TvContract.PreviewPrograms.COLUMN_PACKAGE_NAME,
            TvContract.PreviewPrograms.COLUMN_TITLE,
            TvContract.PreviewPrograms.COLUMN_AUTHOR,
            TvContract.PreviewPrograms.COLUMN_POSTER_ART_URI,
            TvContract.PreviewPrograms.COLUMN_THUMBNAIL_URI,
            TvContract.PreviewPrograms.COLUMN_INTENT_URI,
            TvContract.PreviewPrograms.COLUMN_BROWSABLE,
        };
        try (Cursor cursor = context.getContentResolver().query(
                TvContract.PreviewPrograms.CONTENT_URI, columns, null, null, null)) {
            if (cursor == null) {
                return none;
            }
            while (cursor.moveToNext()) {
                long channelId = cursor.isNull(0) ? -1L : cursor.getLong(0);
                if (!channelNames.containsKey(channelId)) {
                    continue;
                }
                if (!cursor.isNull(7) && cursor.getInt(7) == 0) {
                    continue;
                }
                Item item = new Item();
                item.packageName = text(cursor, 1);
                item.title = text(cursor, 2);
                item.subtitle = text(cursor, 3);
                item.art = text(cursor, 4).isEmpty() ? text(cursor, 5) : text(cursor, 4);
                item.intentUri = text(cursor, 6);
                if (item.title.isEmpty()) {
                    continue;
                }
                List<Item> list = byChannel.get(channelId);
                if (list == null) {
                    list = new ArrayList<>();
                    byChannel.put(channelId, list);
                }
                list.add(item);
            }
        } catch (RuntimeException e) {
            return none;
        }

        // Step 3: pick the row that is the viewer's recommendations. Prefer a
        // row named like one, from a third-party player if there are several.
        long best = -1L;
        int bestScore = -1;
        for (Map.Entry<Long, List<Item>> entry : byChannel.entrySet()) {
            if (entry.getValue().isEmpty()) {
                continue;
            }
            String name = channelNames.get(entry.getKey()).toLowerCase(Locale.US);
            String packageName = channelPackages.get(entry.getKey());
            int score = 0;
            if (name.contains("recommend") || name.contains("for you") || name.equals("home")) {
                score += 10;
            } else if (name.contains("subscription")) {
                score += 4;
            } else if (name.contains("history") || name.contains("trending")
                    || name.contains("music") || name.contains("gaming")) {
                score += 0;
            } else {
                score += 2;
            }
            if (!packageName.startsWith("com.google.")) {
                score += 1;
            }
            if (score > bestScore) {
                bestScore = score;
                best = entry.getKey();
            }
        }
        if (best < 0) {
            return none;
        }
        List<Item> chosen = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (Item item : byChannel.get(best)) {
            if (seen.add(item.title + "|" + item.intentUri) && chosen.size() < MAX_ITEMS) {
                chosen.add(item);
            }
        }
        return chosen;
    }

    private static boolean isYouTubeApp(String packageName) {
        String name = packageName.toLowerCase(Locale.US);
        return name.contains("youtube") || name.contains("smarttube")
                || name.contains("teamsmart") || name.contains("liskovsoft");
    }

    private static String text(Cursor cursor, int column) {
        if (cursor.isNull(column)) {
            return "";
        }
        String value = cursor.getString(column);
        return value == null ? "" : value;
    }

    /** A short fingerprint, so a row is only redrawn when its contents change. */
    static String signature(List<Item> items) {
        StringBuilder builder = new StringBuilder();
        for (Item item : items) {
            builder.append(item.title).append('|').append(item.intentUri).append('|')
                    .append(item.progress).append('\n');
        }
        return builder.toString();
    }

    /**
     * Loads artwork from a web address, or from another app's content when
     * the address is not a web one. Returns null if it cannot be loaded.
     */
    static Bitmap loadArt(Context context, String address) {
        if (address == null || address.isEmpty()) {
            return null;
        }
        if (address.startsWith("http://") || address.startsWith("https://")) {
            return Videos.loadThumbnail(address);
        }
        try (InputStream in = context.getContentResolver().openInputStream(Uri.parse(address))) {
            return in == null ? null : BitmapFactory.decodeStream(in);
        } catch (Exception | OutOfMemoryError e) {
            return null;
        }
    }
}
