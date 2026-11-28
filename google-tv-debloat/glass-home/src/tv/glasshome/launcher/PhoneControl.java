package tv.glasshome.launcher;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.ref.WeakReference;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * A small web page served by Glass Home, so a phone on the same Wi-Fi (an
 * iPhone included) can change its settings in a browser.
 *
 * Safety: it is off until turned on in Customize; it only answers devices on
 * the home network; every change needs a 6-digit PIN that is only shown on the
 * TV; five wrong PINs lock it for a minute; and it only accepts requests that
 * carry its own token header, so other web pages cannot use it behind your back.
 */
final class PhoneControl {

    static final int PORT = 8765;

    private static final String TAG = "GlassPhone";
    private static final String PREF_ENABLED = "phone_control";
    private static final String PREF_PIN = "phone_pin";
    private static final String PREF_TOKENS = "phone_tokens";
    private static final int MAX_HEADER = 8192;
    private static final int MAX_BODY = 16384;
    private static final int MAX_TOKENS = 5;
    private static final int MAX_PIN_TRIES = 5;
    private static final long LOCKOUT_MS = 60_000L;
    private static final String NEEDS_PC = "The TV has not given Glass Home permission for this "
            + "yet. Run the PC tool once and choose option 5.";

    /** The address the browser used. Only plain IP addresses, which blocks DNS-rebinding tricks. */
    private static final Pattern HOST_OK = Pattern.compile(
            "^(\\d{1,3}(\\.\\d{1,3}){3}|localhost|\\[[0-9a-fA-F:.]+\\])(:\\d{1,5})?$");
    private static final Pattern TOKEN_OK = Pattern.compile("^[0-9a-f]{32}$");
    private static final Pattern KEY_OK = Pattern.compile("^[0-9A-Za-z_\\-]{0,100}$");

    /** Apps whose Play Store page the phone can open on the TV. Nothing outside this list. */
    private static final String[][] STORE_APPS = {
        {"com.disney.disneyplus", "Disney+"},
        {"com.hulu.livingroomplus", "Hulu"},
        {"com.wbd.stream", "HBO Max"},
        {"org.videolan.vlc", "VLC"},
        {"org.jellyfin.androidtv", "Jellyfin"},
        {"com.plexapp.android", "Plex"},
    };

    /** The home screen, told when the phone changes something it shows. */
    interface Listener {
        void onPhoneChange(String what);
    }

    private static PhoneControl running;
    private static WeakReference<Listener> listener = new WeakReference<>(null);
    private static byte[] page;

    private final Context context;
    private final Apps.Prefs prefs;
    private final ServerSocket server;
    private final ExecutorService pool = Executors.newFixedThreadPool(3);
    private final SecureRandom random = new SecureRandom();
    private volatile boolean open = true;
    private int failedPins = 0;
    private long lockedUntil = 0L;

    // ------------------------------------------------------------------
    // Turning it on and off
    // ------------------------------------------------------------------

    static boolean isEnabled(Context context) {
        return new Apps.Prefs(context).flag(PREF_ENABLED);
    }

    static synchronized void setEnabled(Context context, boolean on) {
        new Apps.Prefs(context).saveFlag(PREF_ENABLED, on);
        if (on) {
            start(context);
        } else {
            stop();
        }
    }

    static synchronized void start(Context context) {
        if (running != null) {
            return;
        }
        try {
            running = new PhoneControl(context.getApplicationContext());
            Log.i(TAG, "Listening on port " + PORT);
        } catch (IOException e) {
            Log.w(TAG, "Could not start: " + e);
        }
    }

    static synchronized void stop() {
        if (running != null) {
            running.close();
            running = null;
        }
    }

    static synchronized boolean isRunning() {
        return running != null;
    }

    static void setListener(Listener home) {
        listener = new WeakReference<>(home);
    }

    static void clearListener(Listener home) {
        if (listener.get() == home) {
            listener = new WeakReference<>(null);
        }
    }

    /** The PIN shown on the TV. Made on first use. */
    static String pin(Context context) {
        Apps.Prefs prefs = new Apps.Prefs(context);
        String pin = prefs.text(PREF_PIN);
        if (!pin.matches("\\d{6}")) {
            pin = newPin();
            prefs.saveText(PREF_PIN, pin);
        }
        return pin;
    }

    /** A new PIN also signs out every phone that was connected. */
    static void resetPin(Context context) {
        Apps.Prefs prefs = new Apps.Prefs(context);
        prefs.saveText(PREF_PIN, newPin());
        prefs.saveText(PREF_TOKENS, "");
    }

    private static String newPin() {
        return String.format(Locale.US, "%06d", new SecureRandom().nextInt(1_000_000));
    }

    /** The address to type on the phone, or "" if the TV has no home-network address. */
    static String address() {
        try {
            for (NetworkInterface face : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!face.isUp() || face.isLoopback()) {
                    continue;
                }
                for (InetAddress address : Collections.list(face.getInetAddresses())) {
                    if (address instanceof Inet4Address && address.isSiteLocalAddress()) {
                        return "http://" + address.getHostAddress() + ":" + PORT;
                    }
                }
            }
        } catch (IOException | RuntimeException e) {
            // Fall through.
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Server
    // ------------------------------------------------------------------

    private PhoneControl(Context appContext) throws IOException {
        context = appContext;
        prefs = new Apps.Prefs(appContext);
        server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(PORT));
        Thread acceptor = new Thread(this::acceptLoop, "GlassPhoneServer");
        acceptor.setDaemon(true);
        acceptor.start();
    }

    private void close() {
        open = false;
        try {
            server.close();
        } catch (IOException ignored) {
            // Already closed.
        }
        pool.shutdownNow();
    }

    private void acceptLoop() {
        while (open) {
            Socket socket = null;
            try {
                socket = server.accept();
                final Socket accepted = socket;
                pool.execute(() -> handle(accepted));
            } catch (IOException | RuntimeException e) {
                closeQuietly(socket);
                if (!open) {
                    return;
                }
                try {
                    Thread.sleep(200);
                } catch (InterruptedException interrupted) {
                    return;
                }
            }
        }
    }

    private static void closeQuietly(Socket socket) {
        if (socket != null) {
            try {
                socket.close();
            } catch (IOException ignored) {
                // Nothing to do.
            }
        }
    }

    private void handle(Socket socket) {
        try (Socket s = socket) {
            s.setSoTimeout(10000);
            InetAddress remote = s.getInetAddress();
            if (!(remote.isSiteLocalAddress() || remote.isLinkLocalAddress()
                    || remote.isLoopbackAddress())) {
                return; // Only devices on the home network.
            }
            InputStream in = new BufferedInputStream(s.getInputStream());
            OutputStream out = s.getOutputStream();

            String head = readHead(in);
            if (head == null) {
                sendJson(out, 400, error("Bad request"));
                return;
            }
            String[] lines = head.split("\r\n");
            String[] first = lines[0].split(" ");
            if (first.length < 2) {
                sendJson(out, 400, error("Bad request"));
                return;
            }
            String method = first[0];
            String path = first[1];
            int query = path.indexOf('?');
            if (query >= 0) {
                path = path.substring(0, query);
            }
            Map<String, String> headers = new HashMap<>();
            for (int i = 1; i < lines.length; i++) {
                int colon = lines[i].indexOf(':');
                if (colon > 0) {
                    headers.put(lines[i].substring(0, colon).trim().toLowerCase(Locale.US),
                            lines[i].substring(colon + 1).trim());
                }
            }
            if (!HOST_OK.matcher(headers.getOrDefault("host", "")).matches()) {
                sendJson(out, 403, error("Open this page using the TV's number address"));
                return;
            }
            int length;
            try {
                length = Integer.parseInt(headers.getOrDefault("content-length", "0"));
            } catch (NumberFormatException e) {
                length = -1;
            }
            if (length < 0 || length > MAX_BODY) {
                sendJson(out, 413, error("Request too large"));
                return;
            }
            String body = new String(readBody(in, length), StandardCharsets.UTF_8);
            route(method, path, headers, body, out);
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "Request failed: " + e);
        }
    }

    /** Reads up to the blank line that ends the request headers. */
    private static String readHead(InputStream in) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int matched = 0;
        int[] end = {'\r', '\n', '\r', '\n'};
        while (buffer.size() < MAX_HEADER) {
            int b = in.read();
            if (b < 0) {
                return null;
            }
            buffer.write(b);
            matched = b == end[matched] ? matched + 1 : (b == '\r' ? 1 : 0);
            if (matched == 4) {
                byte[] bytes = buffer.toByteArray();
                return new String(bytes, 0, bytes.length - 4, StandardCharsets.ISO_8859_1);
            }
        }
        return null;
    }

    private static byte[] readBody(InputStream in, int length) throws IOException {
        byte[] body = new byte[length];
        int read = 0;
        while (read < length) {
            int count = in.read(body, read, length - read);
            if (count < 0) {
                throw new IOException("Request ended early");
            }
            read += count;
        }
        return body;
    }

    private void route(String method, String path, Map<String, String> headers, String body,
            OutputStream out) throws IOException {
        if (path.equals("/") || path.equals("/index.html")) {
            if (method.equals("GET")) {
                send(out, 200, "text/html; charset=utf-8", page());
            } else {
                sendJson(out, 405, error("Not allowed"));
            }
            return;
        }
        if (path.equals("/api/login") && method.equals("POST")) {
            login(body, out);
            return;
        }
        if (!path.startsWith("/api/")) {
            sendJson(out, 404, error("Not found"));
            return;
        }
        if (!validToken(headers.get("x-glass-token"))) {
            sendJson(out, 401, error("Enter the PIN shown on the TV"));
            return;
        }
        if (path.equals("/api/status") && method.equals("GET")) {
            sendJson(out, 200, status());
        } else if (path.equals("/api/action") && method.equals("POST")) {
            action(body, out);
        } else {
            sendJson(out, 404, error("Not found"));
        }
    }

    // ------------------------------------------------------------------
    // Sign-in
    // ------------------------------------------------------------------

    private void login(String body, OutputStream out) throws IOException {
        String given;
        try {
            given = new JSONObject(body).optString("pin").trim();
        } catch (JSONException e) {
            given = "";
        }
        boolean ok = false;
        long wait = 0;
        synchronized (this) {
            long now = System.currentTimeMillis();
            if (now < lockedUntil) {
                wait = (lockedUntil - now + 999) / 1000;
            } else {
                ok = MessageDigest.isEqual(given.getBytes(StandardCharsets.UTF_8),
                        pin(context).getBytes(StandardCharsets.UTF_8));
                if (ok) {
                    failedPins = 0;
                } else if (++failedPins >= MAX_PIN_TRIES) {
                    failedPins = 0;
                    lockedUntil = now + LOCKOUT_MS;
                }
            }
        }
        if (wait > 0) {
            sendJson(out, 429, error("Too many wrong PINs. Wait " + wait + " seconds."));
            return;
        }
        if (!ok) {
            sendJson(out, 401, error("Wrong PIN. It is on the TV under Customize, Phone control."));
            return;
        }
        JSONObject reply = new JSONObject();
        try {
            reply.put("token", newToken());
        } catch (JSONException e) {
            // Cannot happen with a plain string.
        }
        sendJson(out, 200, reply);
    }

    private synchronized String newToken() {
        byte[] bytes = new byte[16];
        random.nextBytes(bytes);
        StringBuilder token = new StringBuilder();
        for (byte b : bytes) {
            token.append(String.format(Locale.US, "%02x", b & 0xFF));
        }
        List<String> tokens = tokens();
        tokens.add(0, token.toString());
        while (tokens.size() > MAX_TOKENS) {
            tokens.remove(tokens.size() - 1);
        }
        prefs.saveText(PREF_TOKENS, android.text.TextUtils.join("\n", tokens));
        return token.toString();
    }

    private List<String> tokens() {
        List<String> tokens = new ArrayList<>();
        for (String token : prefs.text(PREF_TOKENS).split("\n")) {
            if (TOKEN_OK.matcher(token).matches()) {
                tokens.add(token);
            }
        }
        return tokens;
    }

    private boolean validToken(String given) {
        if (given == null || !TOKEN_OK.matcher(given).matches()) {
            return false;
        }
        boolean found = false;
        for (String token : tokens()) {
            found |= MessageDigest.isEqual(token.getBytes(StandardCharsets.UTF_8),
                    given.getBytes(StandardCharsets.UTF_8));
        }
        return found;
    }

    // ------------------------------------------------------------------
    // What the page shows and does
    // ------------------------------------------------------------------

    private JSONObject status() {
        JSONObject status = new JSONObject();
        try {
            status.put("version", Updater.installedName(context));
            status.put("canWrite", SystemSettings.canWrite(context));
            JSONArray themes = new JSONArray();
            for (GradientView.Palette palette : GradientView.PALETTES) {
                themes.put(palette.name);
            }
            status.put("themes", themes);
            status.put("theme", prefs.palette());
            status.put("motion", prefs.motion());
            status.put("adblock", SystemSettings.isAdBlockOn(context));
            status.put("animations", SystemSettings.animationScale(context));
            status.put("screensaver", SystemSettings.isScreensaverOn(context));
            status.put("admuter", SystemSettings.isAdMuterOn(context));
            status.put("youtubeKey", !prefs.apiKey().isEmpty());
            JSONArray apps = new JSONArray();
            for (String[] app : STORE_APPS) {
                JSONObject item = new JSONObject();
                item.put("id", app[0]);
                item.put("name", app[1]);
                item.put("installed", isInstalled(app[0]));
                apps.put(item);
            }
            status.put("apps", apps);
        } catch (JSONException e) {
            // Only plain values are added.
        }
        return status;
    }

    private boolean isInstalled(String packageName) {
        try {
            context.getPackageManager().getPackageInfo(packageName, 0);
            return true;
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            return false;
        }
    }

    private void action(String body, OutputStream out) throws IOException {
        String action;
        String value;
        try {
            JSONObject request = new JSONObject(body);
            action = request.optString("action");
            value = request.optString("value");
        } catch (JSONException e) {
            sendJson(out, 400, error("Bad request"));
            return;
        }
        boolean on = value.equals("on");
        boolean ok = true;
        String message;

        switch (action) {
            case "theme": {
                int index;
                try {
                    index = Integer.parseInt(value);
                } catch (NumberFormatException e) {
                    index = -1;
                }
                if (index < 0 || index >= GradientView.PALETTES.length) {
                    ok = false;
                    message = "Unknown theme";
                } else {
                    prefs.savePalette(index);
                    notifyHome("theme");
                    message = "Theme set to " + GradientView.PALETTES[index].name;
                }
                break;
            }
            case "motion":
                prefs.saveMotion(on);
                notifyHome("theme");
                message = "Background motion " + (on ? "on" : "off");
                break;
            case "adblock":
                if (!SystemSettings.canWrite(context)) {
                    ok = false;
                    message = NEEDS_PC;
                } else if (!on) {
                    ok = SystemSettings.setAdBlock(context, false);
                    message = ok ? "Ad blocking is off" : NEEDS_PC;
                } else if (!SystemSettings.setAdBlock(context, true)) {
                    ok = false;
                    message = NEEDS_PC;
                } else {
                    // Give the TV a moment, then make sure it can still get online.
                    sleep(4000);
                    if (SystemSettings.online()) {
                        message = "Ad blocking is on";
                    } else {
                        SystemSettings.setAdBlock(context, false);
                        ok = false;
                        message = "The TV could not get online with ad blocking on, so it was "
                                + "switched back off. Your network may block this kind of DNS.";
                    }
                }
                break;
            case "animations":
                if (!Arrays.asList("1", "0.5", "0").contains(value)) {
                    ok = false;
                    message = "Unknown speed";
                } else {
                    ok = SystemSettings.canWrite(context)
                            && SystemSettings.setAnimationScale(context, value);
                    message = ok ? "Animation speed changed" : NEEDS_PC;
                }
                break;
            case "screensaver":
                ok = SystemSettings.canWrite(context)
                        && SystemSettings.setScreensaver(context, prefs, on);
                message = ok ? "Glass Home screensaver " + (on ? "on" : "off") : NEEDS_PC;
                break;
            case "admuter":
                ok = SystemSettings.canWrite(context) && SystemSettings.setAdMuter(context, on);
                message = ok ? "Ad muter " + (on ? "on" : "off") : NEEDS_PC;
                break;
            case "youtube_key": {
                String key = value.trim();
                if (!KEY_OK.matcher(key).matches()) {
                    ok = false;
                    message = "That is not a valid key. It should start with AIza.";
                } else {
                    prefs.saveApiKey(key);
                    notifyHome("youtube");
                    message = key.isEmpty() ? "YouTube key removed" : "YouTube key saved";
                }
                break;
            }
            case "open_store":
                message = openStore(value);
                ok = message.startsWith("Opened");
                break;
            case "check_update":
                ok = notifyHome("update");
                message = ok
                        ? "Checking on the TV. If an update is offered, confirm it with the TV remote."
                        : "Press Home on the TV remote first, then try again.";
                break;
            default:
                ok = false;
                message = "Unknown action";
        }

        JSONObject reply = new JSONObject();
        try {
            reply.put("ok", ok);
            reply.put("message", message);
            reply.put("status", status());
        } catch (JSONException e) {
            // Only plain values are added.
        }
        sendJson(out, 200, reply);
    }

    private String openStore(String packageName) {
        for (String[] app : STORE_APPS) {
            if (app[0].equals(packageName)) {
                try {
                    context.startActivity(new Intent(Intent.ACTION_VIEW,
                            Uri.parse("market://details?id=" + app[0]))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    return "Opened " + app[1] + " in the Play Store on the TV. Press Install with "
                            + "the TV remote. If nothing appeared, press Home on the TV remote "
                            + "and try again.";
                } catch (RuntimeException e) {
                    return "The Play Store could not be opened on the TV";
                }
            }
        }
        return "That app is not on the list";
    }

    /** Tells the home screen something changed. False if the home screen is not running. */
    private static boolean notifyHome(String what) {
        Listener home = listener.get();
        if (home == null) {
            return false;
        }
        home.onPhoneChange(what);
        return true;
    }

    private static void sleep(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // ------------------------------------------------------------------
    // Responses
    // ------------------------------------------------------------------

    private synchronized byte[] page() throws IOException {
        if (page == null) {
            try (InputStream in = context.getResources().openRawResource(R.raw.phone_control)) {
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                byte[] chunk = new byte[8192];
                int count;
                while ((count = in.read(chunk)) != -1) {
                    buffer.write(chunk, 0, count);
                }
                page = buffer.toByteArray();
            }
        }
        return page;
    }

    private static JSONObject error(String message) {
        JSONObject json = new JSONObject();
        try {
            json.put("ok", false);
            json.put("message", message);
        } catch (JSONException e) {
            // Only plain values are added.
        }
        return json;
    }

    private static void sendJson(OutputStream out, int code, JSONObject json) throws IOException {
        send(out, code, "application/json; charset=utf-8",
                json.toString().getBytes(StandardCharsets.UTF_8));
    }

    private static void send(OutputStream out, int code, String type, byte[] body)
            throws IOException {
        String head = "HTTP/1.1 " + code + " " + reason(code) + "\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + body.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "X-Content-Type-Options: nosniff\r\n"
                + "X-Frame-Options: DENY\r\n"
                + "Referrer-Policy: no-referrer\r\n"
                + "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; "
                + "style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; "
                + "form-action 'none'; frame-ancestors 'none'\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.ISO_8859_1));
        out.write(body);
        out.flush();
    }

    private static String reason(int code) {
        switch (code) {
            case 200: return "OK";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 413: return "Payload Too Large";
            case 429: return "Too Many Requests";
            default: return "Error";
        }
    }
}
