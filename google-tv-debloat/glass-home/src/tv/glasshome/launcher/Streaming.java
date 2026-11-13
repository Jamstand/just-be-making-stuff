package tv.glasshome.launcher;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Fetches the "On Disney+ and Hulu" poster row from The Movie Database (TMDB),
 * which tracks what each streaming service carries. The posters only point at
 * the official apps; nothing is played from here.
 */
final class Streaming {

    private Streaming() {
    }

    static final String DISNEY_PACKAGE = "com.disney.disneyplus";
    static final String HULU_PACKAGE = "com.hulu.livingroomplus";

    private static final String API = "https://api.themoviedb.org/3/discover/";
    private static final String POSTER_BASE = "https://image.tmdb.org/t/p/w342";
    private static final int PER_LIST = 8;

    // TMDB's ids for the two services.
    private static final String DISNEY_PROVIDER = "337";
    private static final String HULU_PROVIDER = "15";

    static final class Title {
        String id = "";
        String name = "";
        String poster = "";
        String service = "";
        String packageName = "";
    }

    /**
     * Popular shows and films on both services, taken in turns. Throws with a
     * message fit to show on screen if TMDB rejects the first request.
     *
     * @param key a TMDB "API Key" (32 characters) or "API Read Access Token" (starts with eyJ)
     */
    static List<Title> fetch(String key, String region) throws IOException, JSONException {
        boolean token = key.startsWith("eyJ");
        String auth = token ? "" : "&api_key=" + URLEncoder.encode(key, "UTF-8");
        String bearer = token ? key : null;

        String[][] lists = {
            {"tv", DISNEY_PROVIDER, "Disney+", DISNEY_PACKAGE},
            {"tv", HULU_PROVIDER, "Hulu", HULU_PACKAGE},
            {"movie", DISNEY_PROVIDER, "Disney+", DISNEY_PACKAGE},
            {"movie", HULU_PROVIDER, "Hulu", HULU_PACKAGE},
        };
        List<List<Title>> fetched = new ArrayList<>();
        for (int i = 0; i < lists.length; i++) {
            String[] list = lists[i];
            String url = API + list[0] + "?sort_by=popularity.desc&page=1"
                    + "&with_watch_providers=" + list[1]
                    + "&watch_region=" + URLEncoder.encode(region, "UTF-8") + auth;
            try {
                fetched.add(parse(Videos.get(url, bearer), list[2], list[3]));
            } catch (IOException | JSONException e) {
                if (i == 0) {
                    throw e; // A bad key fails here, on the first request.
                }
            }
        }

        List<Title> titles = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        boolean more = true;
        for (int round = 0; more && round < PER_LIST; round++) {
            more = false;
            for (List<Title> list : fetched) {
                if (round < list.size()) {
                    more = true;
                    Title title = list.get(round);
                    if (seen.add(title.name)) {
                        titles.add(title);
                    }
                }
            }
        }
        return titles;
    }

    private static List<Title> parse(String body, String service, String packageName)
            throws JSONException {
        List<Title> titles = new ArrayList<>();
        JSONArray results = new JSONObject(body).optJSONArray("results");
        if (results == null) {
            return titles;
        }
        for (int i = 0; i < results.length(); i++) {
            JSONObject item = results.optJSONObject(i);
            if (item == null) {
                continue;
            }
            String posterPath = item.isNull("poster_path") ? "" : item.optString("poster_path");
            String name = item.optString("name", item.optString("title"));
            if (posterPath.isEmpty() || name.isEmpty()) {
                continue;
            }
            Title title = new Title();
            title.id = item.optString("id");
            title.name = name;
            title.poster = POSTER_BASE + posterPath;
            title.service = service;
            title.packageName = packageName;
            titles.add(title);
        }
        return titles;
    }

    static String toJson(List<Title> titles) {
        try {
            JSONArray array = new JSONArray();
            for (Title title : titles) {
                JSONObject item = new JSONObject();
                item.put("id", title.id);
                item.put("name", title.name);
                item.put("poster", title.poster);
                item.put("service", title.service);
                item.put("packageName", title.packageName);
                array.put(item);
            }
            return array.toString();
        } catch (JSONException e) {
            return "";
        }
    }

    static List<Title> fromJson(String raw) {
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        try {
            JSONArray array = new JSONArray(raw);
            List<Title> titles = new ArrayList<>();
            for (int i = 0; i < array.length(); i++) {
                JSONObject item = array.optJSONObject(i);
                if (item == null) {
                    continue;
                }
                Title title = new Title();
                title.id = item.optString("id");
                title.name = item.optString("name");
                title.poster = item.optString("poster");
                title.service = item.optString("service");
                title.packageName = item.optString("packageName");
                if (!title.name.isEmpty()) {
                    titles.add(title);
                }
            }
            return titles;
        } catch (JSONException e) {
            return null;
        }
    }
}
