package tv.glasshome.launcher;

import android.accessibilityservice.AccessibilityService;
import android.content.Context;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Mutes the TV while Disney+ or Hulu is showing an ad, and unmutes when the
 * show comes back. The ad still plays in full; only the sound is turned off.
 *
 * It works by reading the on-screen labels of those two apps (and no others)
 * and looking for their "Ad" marker. What those apps expose differs by
 * version, so everything it sees is written to the log under the tag
 * GlassAdMuter; that log is what gets used to tune the patterns below.
 */
public class AdMuteService extends AccessibilityService {

    private static final String TAG = "GlassAdMuter";

    private static final Set<String> WATCHED = new HashSet<>(Arrays.asList(
            "com.disney.disneyplus",
            "com.hulu.livingroomplus",
            "com.hulu.plus"));

    /** Labels that mean an ad is on screen: "Ad", "Ad 1 of 3", "Ad : 0:15", "Advertisement". */
    private static final Pattern AD_TEXT = Pattern.compile(
            "^(ads?|advertisement)(\\s*[\\u00B7\\u2022:|]\\s*.*|\\s+\\d.*|\\s*\\(\\d.*)?$"
            + "|\\bad\\s+\\d+\\s+of\\s+\\d+\\b"
            + "|\\b(video|show|program|programme|movie|content|stream)\\s+will\\s+resume\\b"
            + "|\\bresumes?\\s+(in|after)\\b.*\\b(ad|ads|break)\\b"
            + "|\\bad\\s+break\\b"
            + "|\\bcommercial\\s+break\\b",
            Pattern.CASE_INSENSITIVE);

    /** Internal names apps commonly give their ad badge or ad countdown. */
    private static final String[] AD_VIEW_IDS = {
        "ad_badge", "adbadge", "ad_countdown", "adcountdown", "ad_indicator", "adindicator",
        "ad_timer", "adtimer", "ad_label", "adlabel", "ad_overlay", "adoverlay",
        "ad_progress", "adprogress", "ad_remaining", "adremaining",
    };

    private static final long POLL_MS = 1500L;
    private static final int MAX_NODES = 600;
    /** Checks in a row without the marker before the sound comes back. */
    private static final int CLEAR_CHECKS = 2;
    private static final int MAX_LOGGED = 400;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Set<String> logged = new LinkedHashSet<>();
    private AudioManager audio;
    private boolean polling = false;
    private boolean mutedByUs = false;
    private int checksWithoutAd = 0;
    private int checksOutsideApp = 0;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            check();
            if (polling) {
                handler.postDelayed(this, POLL_MS);
            }
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        audio = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        Log.i(TAG, "Ad muter is on");
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        CharSequence source = event.getPackageName();
        if (source == null || !WATCHED.contains(source.toString())) {
            return; // Every other app is ignored without being looked at.
        }
        if (!polling) {
            polling = true;
            checksOutsideApp = 0;
            checksWithoutAd = 0;
            Log.i(TAG, "Watching " + source);
            handler.post(poll);
        }
    }

    /** One look at the screen: is a watched app in front, and is its ad marker showing? */
    private void check() {
        AccessibilityNodeInfo root = null;
        try {
            root = getRootInActiveWindow();
        } catch (RuntimeException e) {
            // Treated the same as no window.
        }
        String front = root == null || root.getPackageName() == null
                ? "" : root.getPackageName().toString();

        if (!WATCHED.contains(front)) {
            // The viewer left the app (or it has no readable window right now).
            if (++checksOutsideApp >= CLEAR_CHECKS) {
                setMuted(false, "left the app");
                polling = false;
                Log.i(TAG, "Stopped watching");
            }
            return;
        }
        checksOutsideApp = 0;

        String reason = findAdMarker(root, front);
        if (reason != null) {
            checksWithoutAd = 0;
            setMuted(true, reason);
        } else if (++checksWithoutAd >= CLEAR_CHECKS) {
            setMuted(false, "ad marker gone");
        }
    }

    /** Walks the app's on-screen labels. Returns what gave the ad away, or null. */
    private String findAdMarker(AccessibilityNodeInfo root, String packageName) {
        ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
        queue.add(root);
        int visited = 0;
        String found = null;
        while (!queue.isEmpty() && visited < MAX_NODES) {
            AccessibilityNodeInfo node = queue.poll();
            if (node == null) {
                continue;
            }
            visited++;
            String text = node.getText() == null ? "" : node.getText().toString().trim();
            String description = node.getContentDescription() == null
                    ? "" : node.getContentDescription().toString().trim();
            String viewId = node.getViewIdResourceName() == null
                    ? "" : node.getViewIdResourceName();

            if (!text.isEmpty() || !description.isEmpty()) {
                remember(packageName, viewId, text, description);
            }
            if (found == null && node.isVisibleToUser()) {
                if (!text.isEmpty() && AD_TEXT.matcher(text).find()) {
                    found = "text \"" + shorten(text) + "\"";
                } else if (!description.isEmpty() && AD_TEXT.matcher(description).find()) {
                    found = "description \"" + shorten(description) + "\"";
                } else if (!viewId.isEmpty()) {
                    String name = viewId.toLowerCase(Locale.US);
                    for (String marker : AD_VIEW_IDS) {
                        if (name.contains(marker)) {
                            found = "view " + viewId;
                            break;
                        }
                    }
                }
            }
            for (int i = 0; i < node.getChildCount(); i++) {
                try {
                    AccessibilityNodeInfo child = node.getChild(i);
                    if (child != null) {
                        queue.add(child);
                    }
                } catch (RuntimeException e) {
                    // The screen changed while we were reading it; skip this branch.
                }
            }
        }
        return found;
    }

    /** Logs each distinct label once, so the log shows what these apps expose. */
    private void remember(String packageName, String viewId, String text, String description) {
        String line = packageName + " | id=" + viewId + " | text=" + shorten(text)
                + " | desc=" + shorten(description);
        if (logged.size() < MAX_LOGGED && logged.add(line)) {
            Log.i(TAG, "seen: " + line);
        }
    }

    private static String shorten(String value) {
        String oneLine = value.replace('\n', ' ');
        return oneLine.length() > 60 ? oneLine.substring(0, 60) + "..." : oneLine;
    }

    private void setMuted(boolean mute, String reason) {
        if (audio == null || mute == mutedByUs) {
            return;
        }
        // Only ever undo a mute this service applied, never one the viewer chose.
        try {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC,
                    mute ? AudioManager.ADJUST_MUTE : AudioManager.ADJUST_UNMUTE, 0);
            mutedByUs = mute;
            Log.i(TAG, (mute ? "MUTED: " : "UNMUTED: ") + reason
                    + " (stream muted now: " + audio.isStreamMute(AudioManager.STREAM_MUSIC) + ")");
        } catch (RuntimeException e) {
            Log.w(TAG, "Could not change mute: " + e);
        }
    }

    @Override
    public void onInterrupt() {
        setMuted(false, "service interrupted");
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(poll);
        polling = false;
        setMuted(false, "service stopped");
        super.onDestroy();
    }
}
