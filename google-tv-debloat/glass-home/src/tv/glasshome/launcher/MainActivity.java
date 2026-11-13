package tv.glasshome.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.LruCache;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.GridLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextClock;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The home screen: clock and quick buttons at the top, then rows that scroll
 * vertically (Favorites, Recent, and two YouTube rows), plus an "all apps"
 * panel. Everything is built in code, with no layout files.
 */
public class MainActivity extends Activity {

    /** Sent by the PC tool to hand over the YouTube API key without typing it on the TV. */
    public static final String EXTRA_API_KEY = "youtube_api_key";
    /** Same, for the TMDB key behind the Disney+ and Hulu poster row. */
    public static final String EXTRA_TMDB_KEY = "tmdb_api_key";

    private static final String VERSION = "1.2";
    private static final String PREF_TMDB_KEY = "tmdb_api_key";
    private static final String PREF_POSTERS = "poster_cache";
    private static final String PREF_POSTERS_TIME = "poster_cache_time";
    private static final String PREF_AUTO_ADDED = "auto_added_";

    // Sizes in dp. A TV screen is 960 x 540 dp.
    private static final int SIDE_MARGIN = 48;
    private static final int ROWS_TOP_SPACE = 104;
    private static final int POSTER_W = 104;
    private static final int POSTER_H = 156;
    private static final int ANIM_MS = 110;
    private static final int FAV_W = 176;
    private static final int FAV_H = 99;
    private static final int RECENT_W = 132;
    private static final int RECENT_H = 74;
    private static final int VIDEO_W = 200;
    private static final int VIDEO_H = 112;
    private static final int GRID_W = 150;
    private static final int GRID_H = 84;
    private static final int GRID_COLUMNS = 5;
    private static final float FOCUS_SCALE = 1.12f;
    private static final float VIDEO_FOCUS_SCALE = 1.08f;

    private static final long VIDEO_REFRESH_MS = 30 * 60 * 1000L;
    private static final long POSTER_REFRESH_MS = 6 * 60 * 60 * 1000L;

    private static final int GLASS = 0x24FFFFFF;
    private static final int GLASS_EDGE = 0x38FFFFFF;
    private static final int TEXT_DIM = 0xB3FFFFFF;

    /** One titled horizontal row on the home screen. */
    private static final class RowSection {
        LinearLayout root;
        TextView title;
        TextView message;
        HorizontalScrollView scroll;
        LinearLayout row;
        /** What pressing OK on the message card does, if anything. */
        Runnable messageAction;
    }

    /** A ScrollView that leaves scrolling to us, so each row snaps to the same spot. */
    private static final class SnapScrollView extends ScrollView {
        SnapScrollView(Context context) {
            super(context);
        }

        @Override
        protected int computeScrollDeltaToGetChildRectOnScreen(Rect rect) {
            return 0;
        }
    }

    private Apps.Prefs prefs;
    private GradientView background;
    private LinearLayout home;
    private SnapScrollView rowsScroll;
    private RowSection favorites;
    private RowSection recents;
    private RowSection trending;
    private RowSection secondVideos;
    private RowSection posters;
    private FrameLayout allAppsOverlay;
    private ScrollView allAppsScroll;
    private GridLayout allAppsGrid;
    private TextView backgroundButton;
    private TextView motionButton;

    private List<Apps.Entry> apps = new ArrayList<>();
    private String appsSignature = null;
    private boolean recentsDirty = false;
    private boolean videosShown = false;
    private boolean videosLoading = false;
    private boolean postersShown = false;
    private boolean postersLoading = false;
    private volatile String appsFingerprint = null;

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final ExecutorService network = Executors.newFixedThreadPool(3);
    private final LruCache<String, Bitmap> thumbnails = new LruCache<>(60);

    private final BroadcastReceiver packageReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            reloadApps();
        }
    };

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = new Apps.Prefs(this);

        FrameLayout root = new FrameLayout(this);
        background = new GradientView(this);
        background.setPalette(prefs.palette());
        background.setMotion(prefs.motion());
        root.addView(background, matchParent());
        root.addView(buildHome(), matchParent());
        root.addView(buildAllAppsOverlay(), matchParent());
        setContentView(root);

        updateBackgroundLabels();
        acceptApiKey(getIntent());
        reloadApps();
    }

    @Override
    protected void onStart() {
        super.onStart();
        background.setRunning(true);

        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_PACKAGE_ADDED);
        filter.addAction(Intent.ACTION_PACKAGE_REMOVED);
        filter.addAction(Intent.ACTION_PACKAGE_CHANGED);
        filter.addAction(Intent.ACTION_PACKAGE_REPLACED);
        filter.addDataScheme("package");
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(packageReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(packageReceiver, filter);
        }
        // Catch anything installed or removed while the launcher was not visible.
        reloadApps();
        if (recentsDirty) {
            recentsDirty = false;
            renderRecents();
        }
        loadVideos(false);
        loadPosters(false);
    }

    @Override
    protected void onStop() {
        background.setRunning(false);
        try {
            unregisterReceiver(packageReceiver);
        } catch (IllegalArgumentException ignored) {
            // Was not registered.
        }
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        worker.shutdownNow();
        network.shutdownNow();
        super.onDestroy();
    }

    /** Home button pressed while the launcher is already on screen, or a key hand-over. */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (acceptApiKey(intent)) {
            return;
        }
        if (hasWindowFocus()) {
            closeAllApps();
            goToTop();
        }
    }

    @Override
    public void onBackPressed() {
        // A home screen has nowhere to go back to. Back closes the apps panel,
        // or returns to the top row.
        if (isAllAppsOpen()) {
            closeAllApps();
        } else if (rowsScroll.getScrollY() > 0) {
            goToTop();
        }
    }

    private void goToTop() {
        rowsScroll.smoothScrollTo(0, 0);
        favorites.scroll.scrollTo(0, 0);
        if (favorites.row.getChildCount() > 0) {
            favorites.row.getChildAt(0).requestFocus();
        }
    }

    /** Stores API keys delivered in an intent. Returns true if there was one. */
    private boolean acceptApiKey(Intent intent) {
        if (intent == null) {
            return false;
        }
        boolean accepted = false;
        String youtubeKey = intent.getStringExtra(EXTRA_API_KEY);
        if (youtubeKey != null) {
            intent.removeExtra(EXTRA_API_KEY);
            prefs.saveApiKey(youtubeKey.trim());
            videosShown = false;
            toast(youtubeKey.trim().isEmpty() ? "YouTube key removed" : "YouTube key saved");
            if (trending != null) {
                loadVideos(true);
            }
            accepted = true;
        }
        String tmdbKey = intent.getStringExtra(EXTRA_TMDB_KEY);
        if (tmdbKey != null) {
            intent.removeExtra(EXTRA_TMDB_KEY);
            prefs.saveText(PREF_TMDB_KEY, tmdbKey.trim());
            prefs.saveText(PREF_POSTERS, "");
            prefs.saveTime(PREF_POSTERS_TIME, 0L);
            postersShown = false;
            toast(tmdbKey.trim().isEmpty() ? "TMDB key removed" : "TMDB key saved");
            if (posters != null) {
                loadPosters(true);
            }
            accepted = true;
        }
        return accepted;
    }

    // ------------------------------------------------------------------
    // Building the screen
    // ------------------------------------------------------------------

    private View buildHome() {
        home = new LinearLayout(this);
        home.setOrientation(LinearLayout.VERTICAL);

        // Top bar: clock on the left, quick buttons on the right.
        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.TOP);
        topBar.setPadding(dp(SIDE_MARGIN), dp(30), dp(SIDE_MARGIN), 0);

        LinearLayout clockBlock = new LinearLayout(this);
        clockBlock.setOrientation(LinearLayout.VERTICAL);

        TextClock time = new TextClock(this);
        time.setFormat12Hour("h:mm");
        time.setFormat24Hour("H:mm");
        time.setTextColor(Color.WHITE);
        time.setTextSize(TypedValue.COMPLEX_UNIT_SP, 64);
        time.setTypeface(Typeface.create("sans-serif-thin", Typeface.NORMAL));
        time.setIncludeFontPadding(false);
        time.setShadowLayer(dp(12), 0, dp(2), 0x66000000);
        clockBlock.addView(time);

        TextClock date = new TextClock(this);
        date.setFormat12Hour("EEEE, MMMM d");
        date.setFormat24Hour("EEEE, MMMM d");
        date.setTextColor(TEXT_DIM);
        date.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        date.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        date.setShadowLayer(dp(8), 0, dp(1), 0x66000000);
        date.setPadding(dp(3), dp(2), 0, 0);
        clockBlock.addView(date);

        topBar.addView(clockBlock, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER_VERTICAL);
        buttons.setPadding(0, dp(10), 0, 0);
        buttons.addView(makePill("All Apps", v -> openAllApps()));
        buttons.addView(makePill("Settings", v -> openSystemScreen(Settings.ACTION_SETTINGS)));
        buttons.addView(makePill("Wi-Fi", v -> openSystemScreen(Settings.ACTION_WIFI_SETTINGS)));
        backgroundButton = makePill("Background", v -> cycleBackground());
        buttons.addView(backgroundButton);
        motionButton = makePill("Motion", v -> toggleMotion());
        buttons.addView(motionButton);
        topBar.addView(buttons);

        home.addView(topBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // The rows. Favorites starts low on the screen with Recent peeking in
        // below it; moving down slides each row up under the clock.
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setClipChildren(false);
        column.setClipToPadding(false);
        column.setPadding(0, dp(ROWS_TOP_SPACE), 0, dp(260));

        favorites = addSection(column, "Favorites");
        recents = addSection(column, "Recent");
        trending = addSection(column, "Trending on YouTube");
        secondVideos = addSection(column, "For You");
        posters = addSection(column, "On Disney+ and Hulu");
        recents.root.setVisibility(View.GONE);
        secondVideos.root.setVisibility(View.GONE);

        TextView tip = new TextView(this);
        tip.setText("Hold OK on an app for options.  Glass Home " + VERSION
                + ".  Film and TV data from TMDB; this app is not endorsed or certified by TMDB.");
        tip.setTextColor(0x66FFFFFF);
        tip.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tip.setPadding(dp(SIDE_MARGIN + 8), dp(10), dp(SIDE_MARGIN), 0);
        column.addView(tip);

        rowsScroll = new SnapScrollView(this);
        rowsScroll.setVerticalScrollBarEnabled(false);
        rowsScroll.setVerticalFadingEdgeEnabled(true);
        rowsScroll.setFadingEdgeLength(dp(40));
        rowsScroll.addView(column, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        home.addView(rowsScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        return home;
    }

    private RowSection addSection(LinearLayout column, String titleText) {
        RowSection section = new RowSection();
        section.root = new LinearLayout(this);
        section.root.setOrientation(LinearLayout.VERTICAL);
        section.root.setClipChildren(false);
        section.root.setClipToPadding(false);
        section.root.setPadding(0, 0, 0, dp(10));

        section.title = new TextView(this);
        section.title.setText(titleText);
        section.title.setTextColor(TEXT_DIM);
        section.title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        section.title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        section.title.setLetterSpacing(0.08f);
        section.title.setShadowLayer(dp(6), 0, dp(1), 0x66000000);
        section.title.setPadding(dp(SIDE_MARGIN + 8), 0, 0, dp(2));
        section.root.addView(section.title);

        // Shown in place of the tiles (for example "add a key"). It can be
        // focused, so pressing Down always brings the row into view.
        final RowSection self = section;
        final TextView message = new TextView(this);
        section.message = message;
        message.setTextColor(Color.WHITE);
        message.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        message.setLineSpacing(dp(3), 1f);
        message.setPadding(dp(18), dp(14), dp(18), dp(14));
        message.setBackground(glass(GLASS, GLASS_EDGE, 16));
        message.setFocusable(true);
        message.setClickable(true);
        message.setVisibility(View.GONE);
        message.setOnFocusChangeListener((v, focused) -> {
            message.setBackground(focused
                    ? glass(0x40FFFFFF, Color.WHITE, 16, 2)
                    : glass(GLASS, GLASS_EDGE, 16));
            if (focused) {
                snapTo(self);
            }
        });
        message.setOnClickListener(v -> {
            if (self.messageAction != null) {
                self.messageAction.run();
            }
        });
        LinearLayout.LayoutParams messageParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        messageParams.setMargins(dp(SIDE_MARGIN + 8), dp(14), dp(SIDE_MARGIN), dp(16));
        section.root.addView(message, messageParams);

        section.row = new LinearLayout(this);
        section.row.setOrientation(LinearLayout.HORIZONTAL);
        section.row.setClipChildren(false);
        section.row.setClipToPadding(false);
        // The side margin lives inside the row so tiles scroll edge to edge.
        section.row.setPadding(dp(SIDE_MARGIN), dp(18), dp(SIDE_MARGIN), dp(4));

        section.scroll = new HorizontalScrollView(this);
        section.scroll.setHorizontalScrollBarEnabled(false);
        section.scroll.setClipChildren(false);
        section.scroll.setClipToPadding(false);
        section.scroll.addView(section.row, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        section.root.addView(section.scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        column.addView(section.root, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return section;
    }

    /** Shows text in place of a row's tiles, or the tiles if text is null. */
    private void setSectionMessage(RowSection section, String text) {
        boolean showMessage = text != null;
        section.message.setText(showMessage ? text : "");
        section.message.setVisibility(showMessage ? View.VISIBLE : View.GONE);
        section.scroll.setVisibility(showMessage ? View.GONE : View.VISIBLE);
    }

    /** Slides the rows so the given one sits just under the clock. */
    private void snapTo(RowSection section) {
        int target = section == favorites ? 0 : Math.max(0, section.root.getTop() - dp(6));
        rowsScroll.smoothScrollTo(0, target);
    }

    private View buildAllAppsOverlay() {
        allAppsOverlay = new FrameLayout(this);
        allAppsOverlay.setBackgroundColor(0xB8000000);
        allAppsOverlay.setVisibility(View.GONE);

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackground(glass(0x2EFFFFFF, GLASS_EDGE, 28));
        panel.setPadding(dp(20), dp(18), dp(20), dp(8));
        panel.setClipChildren(false);

        TextView title = new TextView(this);
        title.setText("All Apps");
        title.setContentDescription("All Apps, Glass Home " + VERSION);
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        title.setPadding(dp(14), 0, 0, dp(4));
        panel.addView(title);

        allAppsGrid = new GridLayout(this);
        allAppsGrid.setColumnCount(GRID_COLUMNS);
        allAppsGrid.setClipChildren(false);
        allAppsGrid.setClipToPadding(false);
        allAppsGrid.setPadding(dp(6), dp(12), dp(6), dp(16));

        allAppsScroll = new ScrollView(this);
        allAppsScroll.setVerticalScrollBarEnabled(false);
        allAppsScroll.setClipChildren(false);
        allAppsScroll.setClipToPadding(false);
        FrameLayout.LayoutParams gridParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        gridParams.gravity = Gravity.CENTER_HORIZONTAL;
        allAppsScroll.addView(allAppsGrid, gridParams);
        panel.addView(allAppsScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        FrameLayout.LayoutParams panelParams = matchParent();
        panelParams.setMargins(dp(36), dp(30), dp(36), dp(30));
        allAppsOverlay.addView(panel, panelParams);
        return allAppsOverlay;
    }

    /** A rounded glass button in the top bar. Turns solid white when focused. */
    private TextView makePill(String text, View.OnClickListener action) {
        final TextView pill = new TextView(this);
        pill.setText(text);
        pill.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        pill.setTextColor(Color.WHITE);
        pill.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        pill.setSingleLine(true);
        pill.setPadding(dp(16), dp(8), dp(16), dp(8));
        pill.setBackground(glass(GLASS, GLASS_EDGE, 20));
        pill.setFocusable(true);
        pill.setClickable(true);
        pill.setOnClickListener(action);
        pill.setOnFocusChangeListener((v, focused) -> {
            pill.setBackground(focused
                    ? glass(0xF2FFFFFF, Color.WHITE, 20)
                    : glass(GLASS, GLASS_EDGE, 20));
            pill.setTextColor(focused ? 0xFF101014 : Color.WHITE);
            pill.animate().scaleX(focused ? 1.06f : 1f).scaleY(focused ? 1.06f : 1f)
                    .setDuration(ANIM_MS).start();
            if (focused) {
                rowsScroll.smoothScrollTo(0, 0);
            }
        });
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(dp(5), 0, dp(5), 0);
        pill.setLayoutParams(params);
        return pill;
    }

    /**
     * One app tile: a rounded 16:9 card with the app's banner, and its name
     * underneath. The card grows and gets a white edge when focused.
     *
     * @param section the home row it sits in, or null for the All Apps panel
     */
    private View makeTile(final Apps.Entry entry, int widthDp, int heightDp,
            final RowSection section) {
        final boolean reorderable = section == favorites && section != null;
        final LinearLayout tile = new LinearLayout(this);
        tile.setOrientation(LinearLayout.VERTICAL);
        tile.setGravity(Gravity.CENTER_HORIZONTAL);
        tile.setClipChildren(false);
        tile.setClipToPadding(false);
        tile.setFocusable(true);
        tile.setClickable(true);
        tile.setTag(entry.key);

        final FrameLayout card = new FrameLayout(this);
        card.setBackground(glass(GLASS, 0, 14));
        card.setClipToOutline(true);

        if (entry.banner != null) {
            ImageView banner = new ImageView(this);
            banner.setScaleType(ImageView.ScaleType.CENTER_CROP);
            banner.setImageDrawable(entry.banner);
            card.addView(banner, matchParent());
        } else {
            // No TV banner: show the app icon on the glass card instead.
            ImageView icon = new ImageView(this);
            icon.setScaleType(ImageView.ScaleType.FIT_CENTER);
            if (entry.icon != null) {
                icon.setImageDrawable(entry.icon);
            }
            int size = dp(heightDp * 0.56f);
            FrameLayout.LayoutParams iconParams = new FrameLayout.LayoutParams(size, size);
            iconParams.gravity = Gravity.CENTER;
            card.addView(icon, iconParams);
        }

        final View ring = new View(this);
        ring.setBackground(glass(0, Color.WHITE, 14, 2));
        ring.setVisibility(View.INVISIBLE);
        card.addView(ring, matchParent());

        tile.addView(card, new LinearLayout.LayoutParams(dp(widthDp), dp(heightDp)));

        final TextView label = new TextView(this);
        label.setText(entry.label);
        label.setTextColor(Color.WHITE);
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        label.setSingleLine(true);
        label.setEllipsize(TextUtils.TruncateAt.END);
        label.setGravity(Gravity.CENTER);
        label.setShadowLayer(dp(6), 0, dp(1), 0x99000000);
        label.setPadding(0, dp(12), 0, 0);
        // Home rows hide the name until focused; the apps panel always shows it, dimmed.
        final float restingAlpha = section != null ? 0f : 0.6f;
        label.setAlpha(restingAlpha);
        tile.addView(label, new LinearLayout.LayoutParams(
                dp(widthDp), ViewGroup.LayoutParams.WRAP_CONTENT));

        tile.setOnFocusChangeListener((v, focused) -> {
            float scale = focused ? FOCUS_SCALE : 1f;
            card.animate().scaleX(scale).scaleY(scale).setDuration(ANIM_MS).start();
            card.setTranslationZ(focused ? dp(10) : 0);
            ring.setVisibility(focused ? View.VISIBLE : View.INVISIBLE);
            label.animate().alpha(focused ? 1f : restingAlpha).setDuration(ANIM_MS).start();
            if (focused && section != null) {
                snapTo(section);
            }
        });
        tile.setOnClickListener(v -> launch(entry));
        tile.setOnLongClickListener(v -> {
            showAppMenu(entry, reorderable);
            return true;
        });
        tile.setOnKeyListener((v, keyCode, event) -> {
            if (keyCode == KeyEvent.KEYCODE_MENU && event.getAction() == KeyEvent.ACTION_UP) {
                showAppMenu(entry, reorderable);
                return true;
            }
            return false;
        });
        return tile;
    }

    /** One video tile: thumbnail, title and channel name. */
    private View makeVideoTile(final Videos.Video video, final RowSection section) {
        final LinearLayout tile = new LinearLayout(this);
        tile.setOrientation(LinearLayout.VERTICAL);
        tile.setClipChildren(false);
        tile.setClipToPadding(false);
        tile.setFocusable(true);
        tile.setClickable(true);

        final FrameLayout card = new FrameLayout(this);
        card.setBackground(glass(GLASS, 0, 12));
        card.setClipToOutline(true);

        final ImageView thumbnail = new ImageView(this);
        thumbnail.setScaleType(ImageView.ScaleType.CENTER_CROP);
        card.addView(thumbnail, matchParent());
        loadThumbnailInto(thumbnail, video.thumbnail);

        final View ring = new View(this);
        ring.setBackground(glass(0, Color.WHITE, 12, 2));
        ring.setVisibility(View.INVISIBLE);
        card.addView(ring, matchParent());

        tile.addView(card, new LinearLayout.LayoutParams(dp(VIDEO_W), dp(VIDEO_H)));

        final TextView title = new TextView(this);
        title.setText(video.title);
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setShadowLayer(dp(6), 0, dp(1), 0x99000000);
        title.setPadding(dp(2), dp(11), dp(2), 0);
        title.setAlpha(0.75f);
        tile.addView(title, new LinearLayout.LayoutParams(
                dp(VIDEO_W), ViewGroup.LayoutParams.WRAP_CONTENT));

        final TextView channel = new TextView(this);
        channel.setText(video.channel);
        channel.setTextColor(TEXT_DIM);
        channel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        channel.setSingleLine(true);
        channel.setEllipsize(TextUtils.TruncateAt.END);
        channel.setPadding(dp(2), dp(2), dp(2), 0);
        channel.setAlpha(0.6f);
        tile.addView(channel, new LinearLayout.LayoutParams(
                dp(VIDEO_W), ViewGroup.LayoutParams.WRAP_CONTENT));

        tile.setOnFocusChangeListener((v, focused) -> {
            float scale = focused ? VIDEO_FOCUS_SCALE : 1f;
            card.animate().scaleX(scale).scaleY(scale).setDuration(ANIM_MS).start();
            card.setTranslationZ(focused ? dp(10) : 0);
            ring.setVisibility(focused ? View.VISIBLE : View.INVISIBLE);
            title.animate().alpha(focused ? 1f : 0.75f).setDuration(ANIM_MS).start();
            if (focused) {
                snapTo(section);
            }
        });
        tile.setOnClickListener(v -> playVideo(video));
        return tile;
    }

    private void loadThumbnailInto(final ImageView view, final String address) {
        view.setTag(address);
        Bitmap cached = thumbnails.get(address);
        if (cached != null) {
            view.setImageBitmap(cached);
            return;
        }
        if (network.isShutdown()) {
            return;
        }
        network.execute(() -> {
            final Bitmap bitmap = Videos.loadThumbnail(address);
            if (bitmap == null) {
                return;
            }
            runOnUiThread(() -> {
                thumbnails.put(address, bitmap);
                // The view may have been reused for another video meanwhile.
                if (address.equals(view.getTag())) {
                    view.setImageBitmap(bitmap);
                }
            });
        });
    }

    // ------------------------------------------------------------------
    // App list
    // ------------------------------------------------------------------

    private void reloadApps() {
        if (worker.isShutdown()) {
            return;
        }
        worker.execute(() -> {
            // Loading every banner is slow, so skip it when nothing was
            // installed or removed since last time.
            String fingerprint = Apps.fingerprint(MainActivity.this);
            if (!fingerprint.isEmpty() && fingerprint.equals(appsFingerprint)) {
                return;
            }
            final List<Apps.Entry> loaded = Apps.load(MainActivity.this);
            appsFingerprint = fingerprint;
            runOnUiThread(() -> onAppsLoaded(loaded));
        });
    }

    private void onAppsLoaded(List<Apps.Entry> loaded) {
        if (isFinishing() || isDestroyed()) {
            return;
        }
        StringBuilder signature = new StringBuilder();
        for (Apps.Entry entry : loaded) {
            signature.append(entry.key).append('|').append(entry.label).append('\n');
        }
        if (signature.toString().equals(appsSignature)) {
            return;
        }
        appsSignature = signature.toString();
        apps = loaded;

        if (!prefs.hasFavorites() && !apps.isEmpty()) {
            prefs.saveFavorites(Apps.defaultFavorites(apps));
        }
        addStreamingAppsToFavorites();
        renderFavorites(focusedKey());
        renderRecents();
        renderAllApps();
    }

    /** Puts Disney+ and Hulu in Favorites once each, the first time they are seen installed. */
    private void addStreamingAppsToFavorites() {
        List<String> saved = prefs.favorites();
        boolean changed = false;
        for (String packageName : new String[] {
                Streaming.DISNEY_PACKAGE, Streaming.HULU_PACKAGE}) {
            if (prefs.flag(PREF_AUTO_ADDED + packageName)) {
                continue; // Already done once; respect it if the user removed it since.
            }
            for (Apps.Entry entry : apps) {
                if (entry.packageName().equals(packageName)) {
                    prefs.saveFlag(PREF_AUTO_ADDED + packageName, true);
                    if (!saved.contains(entry.key)) {
                        saved.add(entry.key);
                        changed = true;
                    }
                    break;
                }
            }
        }
        if (changed) {
            prefs.saveFavorites(saved);
        }
    }

    /** The app key of whichever tile currently has focus, or null. */
    private String focusedKey() {
        View focused = getCurrentFocus();
        if (focused != null && focused.getTag() instanceof String) {
            return (String) focused.getTag();
        }
        return null;
    }

    private void renderFavorites(String focusKey) {
        boolean rowHadFocus = favorites.row.hasFocus();
        favorites.row.removeAllViews();
        View toFocus = null;
        for (String key : prefs.favorites()) {
            Apps.Entry entry = Apps.find(apps, key);
            if (entry == null) {
                continue; // Uninstalled or disabled; keep it saved in case it comes back.
            }
            View tile = makeTile(entry, FAV_W, FAV_H, favorites);
            favorites.row.addView(tile, tileParams());
            if (key.equals(focusKey)) {
                toFocus = tile;
            }
        }
        boolean empty = favorites.row.getChildCount() == 0;
        setSectionMessage(favorites, empty
                ? "No favorites yet. Open All Apps, then hold OK on an app to add it." : null);

        if (isAllAppsOpen()) {
            return;
        }
        if (toFocus == null && !empty && (rowHadFocus || getCurrentFocus() == null)) {
            toFocus = favorites.row.getChildAt(0);
        }
        if (toFocus != null) {
            final View target = toFocus;
            target.post(target::requestFocus);
        }
    }

    /** Apps opened from this home screen, newest first. */
    private void renderRecents() {
        boolean rowHadFocus = recents.row.hasFocus();
        recents.row.removeAllViews();
        for (String key : prefs.recents()) {
            Apps.Entry entry = Apps.find(apps, key);
            if (entry != null) {
                recents.row.addView(makeTile(entry, RECENT_W, RECENT_H, recents), tileParams());
            }
        }
        boolean empty = recents.row.getChildCount() == 0;
        recents.root.setVisibility(empty ? View.GONE : View.VISIBLE);
        if (rowHadFocus && !isAllAppsOpen()) {
            final View target = empty
                    ? (favorites.row.getChildCount() > 0 ? favorites.row.getChildAt(0) : null)
                    : recents.row.getChildAt(0);
            if (target != null) {
                target.post(target::requestFocus);
            }
        }
    }

    private void renderAllApps() {
        String focusKey = isAllAppsOpen() ? focusedKey() : null;
        allAppsGrid.removeAllViews();
        View toFocus = null;
        for (Apps.Entry entry : apps) {
            View tile = makeTile(entry, GRID_W, GRID_H, null);
            GridLayout.LayoutParams params = new GridLayout.LayoutParams();
            params.setMargins(dp(9), dp(8), dp(9), dp(10));
            allAppsGrid.addView(tile, params);
            if (entry.key.equals(focusKey)) {
                toFocus = tile;
            }
        }
        if (isAllAppsOpen()) {
            if (toFocus == null && allAppsGrid.getChildCount() > 0) {
                toFocus = allAppsGrid.getChildAt(0);
            }
            if (toFocus != null) {
                final View target = toFocus;
                target.post(target::requestFocus);
            }
        }
    }

    private LinearLayout.LayoutParams tileParams() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(dp(8), 0, dp(8), 0);
        return params;
    }

    // ------------------------------------------------------------------
    // YouTube rows
    // ------------------------------------------------------------------

    /**
     * Shows the video rows, from the saved copy when it is recent enough and
     * from YouTube otherwise.
     */
    private void loadVideos(boolean force) {
        final String apiKey = prefs.apiKey();
        if (apiKey.isEmpty()) {
            trending.row.removeAllViews();
            secondVideos.root.setVisibility(View.GONE);
            trending.messageAction = () -> toast("Run the tool on your PC and choose option 7");
            setSectionMessage(trending, "No YouTube key yet, so there are no videos to show.\n"
                    + "On your PC, run the debloat tool and choose option 7.");
            videosShown = false;
            return;
        }

        final Videos.Feed saved = Videos.Feed.fromJson(prefs.videoCache());
        boolean fresh = System.currentTimeMillis() - prefs.videoCacheTime() < VIDEO_REFRESH_MS;
        if (saved != null && !videosShown) {
            renderVideos(saved);
        }
        if ((saved != null && fresh && !force) || videosLoading || network.isShutdown()) {
            return;
        }
        if (saved == null) {
            setSectionMessage(trending, "Loading videos...");
        }

        videosLoading = true;
        final String region = region();
        final List<String> channels = prefs.watchedChannels();
        network.execute(() -> {
            Videos.Feed feed = null;
            String error = null;
            try {
                feed = Videos.fetch(apiKey, region, channels);
            } catch (Exception e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            final Videos.Feed result = feed;
            final String problem = error;
            runOnUiThread(() -> {
                videosLoading = false;
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                if (result != null) {
                    prefs.saveVideoCache(result.toJson());
                    renderVideos(result);
                } else if (saved == null) {
                    trending.messageAction = () -> loadVideos(true);
                    setSectionMessage(trending, "Could not load videos: " + problem
                            + "\nPress OK to try again.");
                }
            });
        });
    }

    private void renderVideos(Videos.Feed feed) {
        // Do not yank the rows out from under the remote while it is on them.
        if (trending.row.hasFocus() || secondVideos.row.hasFocus()) {
            return;
        }
        videosShown = true;

        trending.row.removeAllViews();
        for (Videos.Video video : feed.trending) {
            trending.row.addView(makeVideoTile(video, trending), tileParams());
        }
        setSectionMessage(trending, feed.trending.isEmpty()
                ? "YouTube returned no trending videos for this country." : null);

        secondVideos.row.removeAllViews();
        for (Videos.Video video : feed.second) {
            secondVideos.row.addView(makeVideoTile(video, secondVideos), tileParams());
        }
        secondVideos.title.setText(feed.personal ? "From channels you watch" : "Popular music");
        setSectionMessage(secondVideos, null);
        secondVideos.root.setVisibility(feed.second.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private static String region() {
        String country = Locale.getDefault().getCountry();
        return country != null && country.length() == 2 ? country.toUpperCase(Locale.US) : "US";
    }

    /**
     * Opens a video in whatever app on the TV plays YouTube links. A
     * third-party player is preferred over Google's app when both exist.
     */
    private void playVideo(Videos.Video video) {
        prefs.pushWatchedChannel(video.channelId);
        Intent intent = new Intent(Intent.ACTION_VIEW,
                Uri.parse("https://www.youtube.com/watch?v=" + video.id));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

        String chosen = null;
        try {
            for (ResolveInfo info : getPackageManager().queryIntentActivities(intent, 0)) {
                if (info.activityInfo == null) {
                    continue;
                }
                String candidate = info.activityInfo.packageName;
                if (candidate.equals(getPackageName())) {
                    continue;
                }
                boolean google = candidate.startsWith("com.google.");
                if (chosen == null || !google) {
                    chosen = candidate;
                }
                if (!google) {
                    break;
                }
            }
        } catch (RuntimeException e) {
            chosen = null;
        }

        try {
            if (chosen != null) {
                intent.setPackage(chosen);
            }
            startActivity(intent);
        } catch (RuntimeException e) {
            toast("No app on this TV can play YouTube links");
        }
    }

    // ------------------------------------------------------------------
    // Disney+ and Hulu poster row
    // ------------------------------------------------------------------

    private void loadPosters(boolean force) {
        final String key = prefs.text(PREF_TMDB_KEY);
        if (key.isEmpty()) {
            posters.row.removeAllViews();
            posters.messageAction = () -> toast("Run the tool on your PC and choose option 9");
            setSectionMessage(posters, "No TMDB key yet, so there are no posters to show.\n"
                    + "On your PC, run the debloat tool and choose option 9.");
            postersShown = false;
            return;
        }

        final List<Streaming.Title> saved = Streaming.fromJson(prefs.text(PREF_POSTERS));
        final boolean haveSaved = saved != null && !saved.isEmpty();
        boolean fresh = System.currentTimeMillis() - prefs.time(PREF_POSTERS_TIME)
                < POSTER_REFRESH_MS;
        if (haveSaved && !postersShown) {
            renderPosters(saved);
        }
        if ((haveSaved && fresh && !force) || postersLoading || network.isShutdown()) {
            return;
        }
        if (!haveSaved) {
            posters.messageAction = null;
            setSectionMessage(posters, "Loading posters...");
        }

        postersLoading = true;
        final String region = region();
        network.execute(() -> {
            List<Streaming.Title> titles = null;
            String error = null;
            try {
                titles = Streaming.fetch(key, region);
            } catch (Exception e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            final List<Streaming.Title> result = titles;
            final String problem = error;
            runOnUiThread(() -> {
                postersLoading = false;
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                if (result != null && !result.isEmpty()) {
                    prefs.saveText(PREF_POSTERS, Streaming.toJson(result));
                    prefs.saveTime(PREF_POSTERS_TIME, System.currentTimeMillis());
                    renderPosters(result);
                } else if (!haveSaved) {
                    posters.messageAction = () -> loadPosters(true);
                    setSectionMessage(posters, (problem != null
                            ? "Could not load posters: " + problem
                            : "TMDB lists nothing for Disney+ or Hulu in this country.")
                            + "\nPress OK to try again.");
                }
            });
        });
    }

    private void renderPosters(List<Streaming.Title> titles) {
        if (posters.row.hasFocus()) {
            return;
        }
        postersShown = true;
        posters.row.removeAllViews();
        for (Streaming.Title title : titles) {
            posters.row.addView(makePosterTile(title), tileParams());
        }
        setSectionMessage(posters, null);
    }

    /** One poster: tall artwork, the title, and which service it is on. */
    private View makePosterTile(final Streaming.Title item) {
        final LinearLayout tile = new LinearLayout(this);
        tile.setOrientation(LinearLayout.VERTICAL);
        tile.setClipChildren(false);
        tile.setClipToPadding(false);
        tile.setFocusable(true);
        tile.setClickable(true);

        final FrameLayout card = new FrameLayout(this);
        card.setBackground(glass(GLASS, 0, 12));
        card.setClipToOutline(true);

        ImageView poster = new ImageView(this);
        poster.setScaleType(ImageView.ScaleType.CENTER_CROP);
        card.addView(poster, matchParent());
        loadThumbnailInto(poster, item.poster);

        final View ring = new View(this);
        ring.setBackground(glass(0, Color.WHITE, 12, 2));
        ring.setVisibility(View.INVISIBLE);
        card.addView(ring, matchParent());

        tile.addView(card, new LinearLayout.LayoutParams(dp(POSTER_W), dp(POSTER_H)));

        final TextView name = new TextView(this);
        name.setText(item.name);
        name.setTextColor(Color.WHITE);
        name.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        name.setShadowLayer(dp(6), 0, dp(1), 0x99000000);
        name.setPadding(dp(2), dp(12), dp(2), 0);
        name.setAlpha(0.75f);
        tile.addView(name, new LinearLayout.LayoutParams(
                dp(POSTER_W), ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView service = new TextView(this);
        service.setText(item.service);
        service.setTextColor(TEXT_DIM);
        service.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        service.setSingleLine(true);
        service.setPadding(dp(2), dp(1), dp(2), 0);
        service.setAlpha(0.6f);
        tile.addView(service, new LinearLayout.LayoutParams(
                dp(POSTER_W), ViewGroup.LayoutParams.WRAP_CONTENT));

        tile.setOnFocusChangeListener((v, focused) -> {
            float scale = focused ? VIDEO_FOCUS_SCALE : 1f;
            card.animate().scaleX(scale).scaleY(scale).setDuration(ANIM_MS).start();
            card.setTranslationZ(focused ? dp(10) : 0);
            ring.setVisibility(focused ? View.VISIBLE : View.INVISIBLE);
            name.animate().alpha(focused ? 1f : 0.75f).setDuration(ANIM_MS).start();
            if (focused) {
                snapTo(posters);
            }
        });
        tile.setOnClickListener(v -> openStreamingApp(item));
        return tile;
    }

    /**
     * Opens the official app for a poster. It cannot jump to the exact title,
     * so the name is shown to make it easy to find.
     */
    private void openStreamingApp(Streaming.Title item) {
        Intent intent = getPackageManager().getLeanbackLaunchIntentForPackage(item.packageName);
        if (intent == null) {
            intent = getPackageManager().getLaunchIntentForPackage(item.packageName);
        }
        try {
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(intent);
                Toast.makeText(this, "Look for \"" + item.name + "\" in " + item.service,
                        Toast.LENGTH_LONG).show();
            } else {
                startActivity(new Intent(Intent.ACTION_VIEW,
                        Uri.parse("market://details?id=" + item.packageName))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                toast(item.service + " is not installed yet");
            }
        } catch (RuntimeException e) {
            toast(item.service + " could not be opened");
        }
    }

    // ------------------------------------------------------------------
    // All apps panel
    // ------------------------------------------------------------------

    private boolean isAllAppsOpen() {
        return allAppsOverlay.getVisibility() == View.VISIBLE;
    }

    private void openAllApps() {
        if (isAllAppsOpen()) {
            return;
        }
        // Keep the remote from wandering onto the home screen underneath.
        home.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        allAppsOverlay.setAlpha(0f);
        allAppsOverlay.setVisibility(View.VISIBLE);
        allAppsOverlay.animate().alpha(1f).setDuration(180).start();
        allAppsScroll.scrollTo(0, 0);
        if (allAppsGrid.getChildCount() > 0) {
            allAppsGrid.getChildAt(0).requestFocus();
        }
    }

    private void closeAllApps() {
        if (!isAllAppsOpen()) {
            return;
        }
        allAppsOverlay.setVisibility(View.GONE);
        home.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
        if (favorites.row.getChildCount() > 0) {
            favorites.row.getChildAt(0).requestFocus();
        } else {
            home.requestFocus();
        }
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    private void launch(Apps.Entry entry) {
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(entry.leanback
                ? Intent.CATEGORY_LEANBACK_LAUNCHER : Intent.CATEGORY_LAUNCHER);
        intent.setComponent(entry.component);
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try {
            startActivity(intent);
            prefs.pushRecent(entry.key);
            // Redrawn when the home screen comes back, not while the app is opening.
            recentsDirty = true;
        } catch (RuntimeException e) {
            toast("Could not open " + entry.label);
        }
    }

    private void openSystemScreen(String action) {
        try {
            startActivity(new Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (RuntimeException e) {
            // Some TVs lack the specific screen; fall back to the main settings page.
            try {
                startActivity(new Intent(Settings.ACTION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (RuntimeException e2) {
                toast("Settings could not be opened");
            }
        }
    }

    private void cycleBackground() {
        int next = (prefs.palette() + 1) % GradientView.PALETTES.length;
        prefs.savePalette(next);
        background.setPalette(next);
        updateBackgroundLabels();
    }

    private void toggleMotion() {
        boolean enabled = !prefs.motion();
        prefs.saveMotion(enabled);
        background.setMotion(enabled);
        updateBackgroundLabels();
    }

    private void updateBackgroundLabels() {
        int index = prefs.palette();
        if (index < 0 || index >= GradientView.PALETTES.length) {
            index = 0;
        }
        backgroundButton.setText(GradientView.PALETTES[index].name);
        motionButton.setText(prefs.motion() ? "Motion: On" : "Motion: Off");
    }

    /** The menu shown when OK is held on an app. */
    private void showAppMenu(final Apps.Entry entry, boolean reorderable) {
        final List<String> saved = prefs.favorites();
        final int position = saved.indexOf(entry.key);
        final List<String> names = new ArrayList<>();
        final List<Runnable> actions = new ArrayList<>();

        names.add("Open");
        actions.add(() -> launch(entry));

        if (position < 0) {
            names.add("Add to favorites");
            actions.add(() -> {
                saved.add(entry.key);
                prefs.saveFavorites(saved);
                renderFavorites(null);
                toast(entry.label + " added to favorites");
            });
        } else {
            if (reorderable && position > 0) {
                names.add("Move left");
                actions.add(() -> moveFavorite(saved, position, position - 1, entry.key));
            }
            if (reorderable && position < saved.size() - 1) {
                names.add("Move right");
                actions.add(() -> moveFavorite(saved, position, position + 1, entry.key));
            }
            names.add("Remove from favorites");
            actions.add(() -> {
                saved.remove(entry.key);
                prefs.saveFavorites(saved);
                renderFavorites(null);
            });
        }

        names.add("App info");
        actions.add(() -> {
            try {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", entry.packageName(), null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (RuntimeException e) {
                toast("App info could not be opened");
            }
        });

        names.add("Uninstall");
        actions.add(() -> {
            try {
                startActivity(new Intent(Intent.ACTION_DELETE,
                        Uri.fromParts("package", entry.packageName(), null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (RuntimeException e) {
                toast("This app cannot be uninstalled from here");
            }
        });

        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle(entry.label)
                .setItems(names.toArray(new String[0]), (dialog, which) -> actions.get(which).run())
                .show();
    }

    private void moveFavorite(List<String> saved, int from, int to, String key) {
        String moved = saved.remove(from);
        saved.add(to, moved);
        prefs.saveFavorites(saved);
        renderFavorites(key);
    }

    // ------------------------------------------------------------------
    // Small helpers
    // ------------------------------------------------------------------

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value,
                getResources().getDisplayMetrics()));
    }

    private static FrameLayout.LayoutParams matchParent() {
        return new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
    }

    private GradientDrawable glass(int fill, int edge, int radiusDp) {
        return glass(fill, edge, radiusDp, 1);
    }

    /** A rounded translucent panel: the "frosted glass" used everywhere. */
    private GradientDrawable glass(int fill, int edge, int radiusDp, int edgeDp) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setShape(GradientDrawable.RECTANGLE);
        drawable.setCornerRadius(dp(radiusDp));
        drawable.setColor(fill);
        if (edge != 0) {
            drawable.setStroke(dp(edgeDp), edge);
        }
        return drawable;
    }
}
