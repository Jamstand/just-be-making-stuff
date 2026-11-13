package tv.glasshome.launcher;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Fetches the two video rows from the YouTube Data API.
 *
 * The API has no "recommended for you" feed, so the rows are:
 *   1. Trending in the TV's country.
 *   2. New uploads from channels whose videos were opened from this home
 *      screen. Until there is some history, popular music stands in.
 */
final class Videos {

    private Videos() {
    }

    private static final String API = "https://www.googleapis.com/youtube/v3/";
    private static final int TIMEOUT_MS = 10000;
    private static final int MAX_CHANNELS = 5;
    private static final String MUSIC_CATEGORY = "10";

    static final class Video {
        String id = "";
        String title = "";
        String channel = "";
        String channelId = "";
        String thumbnail = "";
    }

    /** Both rows, as fetched. */
    static final class Feed {
        List<Video> trending = new ArrayList<>();
        List<Video> second = new ArrayList<>();
        /** True when the second row comes from channels the viewer has watched. */
        boolean personal;

        String toJson() {
            try {
                JSONObject root = new JSONObject();
                root.put("trending", listToJson(trending));
                root.put("second", listToJson(second));
                root.put("personal", personal);
                return root.toString();
            } catch (JSONException e) {
                return "";
            }
        }

        static Feed fromJson(String raw) {
            if (raw == null || raw.isEmpty()) {
                return null;
            }
            try {
                JSONObject root = new JSONObject(raw);
                Feed feed = new Feed();
                feed.trending = listFromJson(root.optJSONArray("trending"));
                feed.second = listFromJson(root.optJSONArray("second"));
                feed.personal = root.optBoolean("personal", false);
                return feed;
            } catch (JSONException e) {
                return null;
            }
        }

        private static JSONArray listToJson(List<Video> videos) throws JSONException {
            JSONArray array = new JSONArray();
            for (Video video : videos) {
                JSONObject item = new JSONObject();
                item.put("id", video.id);
                item.put("title", video.title);
                item.put("channel", video.channel);
                item.put("channelId", video.channelId);
                item.put("thumbnail", video.thumbnail);
                array.put(item);
            }
            return array;
        }

        private static List<Video> listFromJson(JSONArray array) {
            List<Video> videos = new ArrayList<>();
            if (array == null) {
                return videos;
            }
            for (int i = 0; i < array.length(); i++) {
                JSONObject item = array.optJSONObject(i);
                if (item == null) {
                    continue;
                }
                Video video = new Video();
                video.id = item.optString("id");
                video.title = item.optString("title");
                video.channel = item.optString("channel");
                video.channelId = item.optString("channelId");
                video.thumbnail = item.optString("thumbnail");
                if (!video.id.isEmpty()) {
                    videos.add(video);
                }
            }
            return videos;
        }
    }

    /**
     * Downloads both rows. Throws if the trending request fails, with a message
     * fit to show on screen (for example a rejected API key).
     */
    static Feed fetch(String apiKey, String region, List<String> watchedChannels)
            throws IOException, JSONException {
        String key = URLEncoder.encode(apiKey, "UTF-8");
        String country = URLEncoder.encode(region, "UTF-8");
        String popular = API + "videos?part=snippet&chart=mostPopular&maxResults=20"
                + "&regionCode=" + country + "&key=" + key;

        Feed feed = new Feed();
        feed.trending = parseVideos(get(popular), false);

        Set<String> alreadyShown = new HashSet<>();
        for (Video video : feed.trending) {
            alreadyShown.add(video.id);
        }

        // Second row: newest uploads from watched channels, taken in turns so
        // one channel does not fill the whole row.
        List<List<Video>> perChannel = new ArrayList<>();
        int used = 0;
        for (String channelId : watchedChannels) {
            if (used >= MAX_CHANNELS) {
                break;
            }
            if (channelId == null || !channelId.startsWith("UC") || channelId.length() < 3) {
                continue;
            }
            used++;
            // Every channel has an "uploads" playlist: its id with UC swapped for UU.
            String uploads = "UU" + channelId.substring(2);
            String url = API + "playlistItems?part=snippet&maxResults=8&playlistId="
                    + URLEncoder.encode(uploads, "UTF-8") + "&key=" + key;
            try {
                perChannel.add(parseVideos(get(url), true));
            } catch (IOException | JSONException e) {
                // One channel failing should not empty the row.
            }
        }
        boolean more = true;
        for (int round = 0; more; round++) {
            more = false;
            for (List<Video> channelVideos : perChannel) {
                if (round < channelVideos.size()) {
                    more = true;
                    Video video = channelVideos.get(round);
                    if (alreadyShown.add(video.id)) {
                        feed.second.add(video);
                    }
                }
            }
        }
        feed.personal = !feed.second.isEmpty();

        if (feed.second.isEmpty()) {
            try {
                List<Video> music = parseVideos(get(popular + "&videoCategoryId=" + MUSIC_CATEGORY), false);
                for (Video video : music) {
                    if (alreadyShown.add(video.id)) {
                        feed.second.add(video);
                    }
                }
            } catch (IOException | JSONException e) {
                // Not every country has a music chart; the row is simply hidden.
            }
        }
        return feed;
    }

    /** Reads a videos.list or playlistItems.list response. */
    private static List<Video> parseVideos(String body, boolean playlistItems) throws JSONException {
        List<Video> videos = new ArrayList<>();
        JSONArray items = new JSONObject(body).optJSONArray("items");
        if (items == null) {
            return videos;
        }
        for (int i = 0; i < items.length(); i++) {
            JSONObject item = items.optJSONObject(i);
            JSONObject snippet = item == null ? null : item.optJSONObject("snippet");
            if (snippet == null) {
                continue;
            }
            Video video = new Video();
            video.title = snippet.optString("title");
            if (playlistItems) {
                JSONObject resource = snippet.optJSONObject("resourceId");
                video.id = resource == null ? "" : resource.optString("videoId");
                video.channel = snippet.optString("videoOwnerChannelTitle");
                video.channelId = snippet.optString("videoOwnerChannelId");
            } else {
                video.id = item.optString("id");
                video.channel = snippet.optString("channelTitle");
                video.channelId = snippet.optString("channelId");
            }
            JSONObject thumbnails = snippet.optJSONObject("thumbnails");
            if (thumbnails != null) {
                for (String size : new String[] {"medium", "high", "default"}) {
                    JSONObject thumbnail = thumbnails.optJSONObject(size);
                    if (thumbnail != null && !thumbnail.optString("url").isEmpty()) {
                        video.thumbnail = thumbnail.optString("url");
                        break;
                    }
                }
            }
            boolean unavailable = video.title.equals("Private video")
                    || video.title.equals("Deleted video");
            if (!video.id.isEmpty() && !unavailable) {
                videos.add(video);
            }
        }
        return videos;
    }

    private static String get(String address) throws IOException {
        return get(address, null);
    }

    /** HTTP GET returning the body as text, optionally with a bearer token. */
    static String get(String address, String bearerToken) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        try {
            if (bearerToken != null) {
                connection.setRequestProperty("Authorization", "Bearer " + bearerToken);
            }
            connection.setRequestProperty("Accept", "application/json");
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            int status = connection.getResponseCode();
            InputStream stream = status >= 400
                    ? connection.getErrorStream() : connection.getInputStream();
            String body = stream == null ? "" : new String(readAll(stream), "UTF-8");
            if (status >= 400) {
                String message = "The server returned error " + status;
                try {
                    JSONObject error = new JSONObject(body);
                    if (error.has("error")) {
                        message = error.getJSONObject("error").getString("message");
                    } else if (error.has("status_message")) {
                        message = error.getString("status_message");
                    }
                } catch (JSONException e) {
                    // Keep the generic message.
                }
                throw new IOException(message);
            }
            return body;
        } finally {
            connection.disconnect();
        }
    }

    /** Downloads one thumbnail. Returns null if it cannot be loaded. */
    static Bitmap loadThumbnail(String address) {
        if (address == null || address.isEmpty()) {
            return null;
        }
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(address).openConnection();
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            if (connection.getResponseCode() != 200) {
                return null;
            }
            byte[] bytes = readAll(connection.getInputStream());
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        } catch (IOException | RuntimeException | OutOfMemoryError e) {
            return null;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static byte[] readAll(InputStream stream) throws IOException {
        try (InputStream in = stream) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int count;
            while ((count = in.read(chunk)) != -1) {
                out.write(chunk, 0, count);
            }
            return out.toByteArray();
        }
    }
}
