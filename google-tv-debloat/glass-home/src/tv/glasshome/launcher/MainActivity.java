package tv.glasshome.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ComponentName;
import android.content.pm.PackageInstaller;
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

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
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

    private static final String PREF_ROW_ORDER = "row_order";
    private static final String PREF_ROW_HIDDEN = "row_hidden_";
    private static final String PREF_HIDDEN_APPS = "hidden_apps";
    private static final String PREF_UPDATE_CHECKED = "update_checked_at";
    private static final String PREF_UPDATE_CODE = "update_available_code";
    private static final String PREF_SCREENSAVER_BEFORE = "screensaver_before";
    private static final long UPDATE_CHECK_MS = 12 * 60 * 60 * 1000L;
    private static final String[] DEFAULT_ROW_ORDER = {
        "favorites", "recents", "trending", "second", "continue"};
    private static final int PERMISSION_REQUEST = 1;
    private static final String PREF_AUTO_ADDED = "auto_added_";

    // Sizes in dp. A TV screen is 960 x 540 dp.
    private static final int SIDE_MARGIN = 48;
    private static final int ROWS_TOP_SPACE = 104;
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
        /** Short name used when saving the row's settings. */
        String id = "";
        /** Name shown for the row on the settings screen. */
        String settingsName = "";
        /** False while the row has nothing to show and hides itself. */
        boolean hasContent = true;
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
    private RowSection continueWatching;
    private FrameLayout allAppsOverlay;
    private ScrollView allAppsScroll;
    private GridLayout allAppsGrid;
    private LinearLayout column;
    private FrameLayout settingsOverlay;
    private FrameLayout themeOverlay;
    private TextView updateButton;
    private RowSection[] sections = new RowSection[0];
    private boolean updateBusy = false;

    private List<Apps.Entry> apps = new ArrayList<>();
    private String appsSignature = null;
    private boolean recentsDirty = false;
    private boolean videosShown = false;
    private boolean videosLoading = false;
    /** Videos a YouTube app recommends for its signed-in viewer; empty if none publishes any. */
    private List<TvFeed.Item> recommended = new ArrayList<>();
    private String recommendedSignature = "";
    private String continueSignature = null;
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
        settingsOverlay = new FrameLayout(this);
        settingsOverlay.setBackgroundColor(0xB8000000);
        settingsOverlay.setVisibility(View.GONE);
        root.addView(settingsOverlay, matchParent());
        themeOverlay = new FrameLayout(this);
        themeOverlay.setBackgroundColor(0x99000000);
        themeOverlay.setVisibility(View.GONE);
        root.addView(themeOverlay, matchParent());
        setContentView(root);

        handleInstallStatus(getIntent());
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
        loadTvRows();
        checkForUpdateQuietly();
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
        if (handleInstallStatus(intent) || acceptApiKey(intent)) {
            return;
        }
        if (hasWindowFocus()) {
            closeThemePicker(false);
            closeSettings();
            closeAllApps();
            goToTop();
        }
    }

    @Override
    public void onBackPressed() {
        // A home screen has nowhere to go back to. Back closes the apps panel,
        // or returns to the top row.
        if (isThemePickerOpen()) {
            closeThemePicker(true);
        } else if (isSettingsOpen()) {
            closeSettings();
        } else if (isAllAppsOpen()) {
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
        buttons.addView(makePill("TV Settings", v -> openSystemScreen(Settings.ACTION_SETTINGS)));
        buttons.addView(makePill("Wi-Fi", v -> openSystemScreen(Settings.ACTION_WIFI_SETTINGS)));
        buttons.addView(makePill("Customize", v -> openSettings(0)));
        // Only appears when a newer build has been found.
        updateButton = makePill("Update", v -> startUpdateCheck(true));
        updateButton.setVisibility(
                prefs.time(PREF_UPDATE_CODE) > Updater.installedCode(this)
                        ? View.VISIBLE : View.GONE);
        buttons.addView(updateButton);
        topBar.addView(buttons);

        home.addView(topBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // The rows. Favorites starts low on the screen with Recent peeking in
        // below it; moving down slides each row up under the clock.
        column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setClipChildren(false);
        column.setClipToPadding(false);
        column.setPadding(0, dp(ROWS_TOP_SPACE), 0, dp(260));

        favorites = addSection(column, "Favorites");
        recents = addSection(column, "Recent");
        trending = addSection(column, "Trending on YouTube");
        secondVideos = addSection(column, "For You");
        continueWatching = addSection(column, "Continue watching");
        name(favorites, "favorites", "Favorites");
        name(recents, "recents", "Recent apps");
        name(trending, "trending", "YouTube: recommended or trending");
        name(secondVideos, "second", "YouTube: channels you watch");
        name(continueWatching, "continue", "Continue watching");
        sections = new RowSection[] {
            favorites, recents, trending, secondVideos, continueWatching};
        setHasContent(recents, false);
        setHasContent(secondVideos, false);
        applyRowOrder();

        TextView tip = new TextView(this);
        tip.setText("Hold OK on an app for options.  Glass Home "
                + Updater.installedName(this));
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
        // The first row on screen rests low, with the next one peeking in.
        int target = section == firstVisibleSection()
                ? 0 : Math.max(0, section.root.getTop() - dp(6));
        rowsScroll.smoothScrollTo(0, target);
    }

    private RowSection firstVisibleSection() {
        for (int i = 0; i < column.getChildCount(); i++) {
            View child = column.getChildAt(i);
            if (child.getVisibility() != View.VISIBLE) {
                continue;
            }
            for (RowSection section : sections) {
                if (section.root == child) {
                    return section;
                }
            }
        }
        return favorites;
    }

    private static void name(RowSection section, String id, String settingsName) {
        section.id = id;
        section.settingsName = settingsName;
    }

    /** Favorites cannot be hidden; every other row can be, from the settings screen. */
    private boolean rowEnabled(RowSection section) {
        return section == favorites || !prefs.flag(PREF_ROW_HIDDEN + section.id);
    }

    /** A row shows when the viewer has not hidden it and it has something to show. */
    private void setHasContent(RowSection section, boolean hasContent) {
        section.hasContent = hasContent;
        section.root.setVisibility(
                hasContent && rowEnabled(section) ? View.VISIBLE : View.GONE);
    }

    private List<String> rowOrder() {
        List<String> order = new ArrayList<>();
        for (String id : prefs.text(PREF_ROW_ORDER).split(",")) {
            if (Arrays.asList(DEFAULT_ROW_ORDER).contains(id) && !order.contains(id)) {
                order.add(id);
            }
        }
        for (String id : DEFAULT_ROW_ORDER) {
            if (!order.contains(id)) {
                order.add(id);
            }
        }
        return order;
    }

    private RowSection sectionById(String id) {
        for (RowSection section : sections) {
            if (section.id.equals(id)) {
                return section;
            }
        }
        return null;
    }

    /** Puts the rows in the saved order and applies which ones are hidden. */
    private void applyRowOrder() {
        int position = 0;
        for (String id : rowOrder()) {
            RowSection section = sectionById(id);
            if (section == null) {
                continue;
            }
            column.removeView(section.root);
            column.addView(section.root, position++);
            setHasContent(section, section.hasContent);
        }
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
        if (address == null || address.isEmpty()) {
            return;
        }
        Bitmap cached = thumbnails.get(address);
        if (cached != null) {
            view.setImageBitmap(cached);
            return;
        }
        if (network.isShutdown()) {
            return;
        }
        network.execute(() -> {
            final Bitmap bitmap = TvFeed.loadArt(MainActivity.this, address);
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
                Apps.DISNEY_PACKAGE, Apps.HULU_PACKAGE}) {
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

        if (isOverlayOpen()) {
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
        List<String> hidden = hiddenApps();
        for (String key : prefs.recents()) {
            Apps.Entry entry = Apps.find(apps, key);
            if (entry != null && !hidden.contains(key)) {
                recents.row.addView(makeTile(entry, RECENT_W, RECENT_H, recents), tileParams());
            }
        }
        boolean empty = recents.row.getChildCount() == 0;
        setHasContent(recents, !empty);
        if (rowHadFocus && !isOverlayOpen()) {
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
        List<String> hidden = hiddenApps();
        for (Apps.Entry entry : apps) {
            if (hidden.contains(entry.key)) {
                continue;
            }
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
            setHasContent(secondVideos, false);
            videosShown = false;
            if (showingRecommended()) {
                return;
            }
            trending.row.removeAllViews();
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
        if (saved == null && !showingRecommended()) {
            trending.messageAction = null;
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
                } else if (saved == null && !showingRecommended()) {
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

        // Trending is only the stand-in for when no YouTube app on the TV
        // publishes personal recommendations.
        if (!showingRecommended()) {
            trending.title.setText("Trending on YouTube");
            trending.row.removeAllViews();
            for (Videos.Video video : feed.trending) {
                trending.row.addView(makeVideoTile(video, trending), tileParams());
            }
            trending.messageAction = null;
            setSectionMessage(trending, feed.trending.isEmpty()
                    ? "YouTube returned no trending videos for this country." : null);
        }

        secondVideos.row.removeAllViews();
        for (Videos.Video video : feed.second) {
            secondVideos.row.addView(makeVideoTile(video, secondVideos), tileParams());
        }
        secondVideos.title.setText(feed.personal ? "From channels you watch" : "Popular music");
        setSectionMessage(secondVideos, null);
        setHasContent(secondVideos, !feed.second.isEmpty());
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
    // Rows read from other apps: Recommended on YouTube, Continue watching
    // ------------------------------------------------------------------

    private boolean showingRecommended() {
        return !recommended.isEmpty();
    }

    /** Reads what the TV's apps have published, off the main thread, then draws both rows. */
    private void loadTvRows() {
        if (!TvFeed.hasPermission(this)) {
            continueSignature = null;
            continueWatching.row.removeAllViews();
            continueWatching.messageAction = this::askForTvPermission;
            setSectionMessage(continueWatching, "Glass Home needs permission to read what "
                    + "your apps list as \"continue watching\".\nPress OK to allow it.");
            return;
        }
        if (worker.isShutdown()) {
            return;
        }
        worker.execute(() -> {
            final List<TvFeed.Item> watching = TvFeed.watchNext(MainActivity.this);
            final List<TvFeed.Item> suggested = TvFeed.youtubeRecommended(MainActivity.this);
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                renderContinueWatching(watching);
                renderRecommended(suggested);
            });
        });
    }

    private void askForTvPermission() {
        try {
            requestPermissions(new String[] {TvFeed.PERMISSION}, PERMISSION_REQUEST);
        } catch (RuntimeException e) {
            toast("Run the tool on your PC and choose option 5 to allow this");
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions,
            int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != PERMISSION_REQUEST) {
            return;
        }
        if (TvFeed.hasPermission(this)) {
            loadTvRows();
        } else {
            toast("Not allowed. Run the tool on your PC and choose option 5 to allow it.");
        }
    }

    private void renderContinueWatching(List<TvFeed.Item> items) {
        String signature = TvFeed.signature(items);
        if (signature.equals(continueSignature) || continueWatching.row.hasFocus()) {
            return;
        }
        continueSignature = signature;
        continueWatching.row.removeAllViews();
        for (TvFeed.Item item : items) {
            continueWatching.row.addView(makeProgramTile(item, continueWatching, true),
                    tileParams());
        }
        continueWatching.messageAction = null;
        setSectionMessage(continueWatching, items.isEmpty()
                ? "Nothing to continue yet.\nShows and films you start in Disney+, Hulu and "
                        + "other apps appear here once those apps report them."
                : null);
    }

    private void renderRecommended(List<TvFeed.Item> items) {
        String signature = TvFeed.signature(items);
        if (signature.equals(recommendedSignature) || trending.row.hasFocus()) {
            return;
        }
        recommendedSignature = signature;
        boolean hadRecommended = showingRecommended();
        recommended = items;
        if (items.isEmpty()) {
            if (hadRecommended) {
                // The app stopped publishing them: fall back to trending.
                videosShown = false;
                loadVideos(false);
            }
            return;
        }
        trending.title.setText("Recommended on YouTube");
        trending.row.removeAllViews();
        for (TvFeed.Item item : items) {
            trending.row.addView(makeProgramTile(item, trending, false), tileParams());
        }
        trending.messageAction = null;
        setSectionMessage(trending, null);
    }

    /** One entry published by another app: artwork, title, and a progress bar if known. */
    private View makeProgramTile(final TvFeed.Item item, final RowSection section,
            boolean showAppName) {
        final LinearLayout tile = new LinearLayout(this);
        tile.setOrientation(LinearLayout.VERTICAL);
        tile.setClipChildren(false);
        tile.setClipToPadding(false);
        tile.setFocusable(true);
        tile.setClickable(true);

        final FrameLayout card = new FrameLayout(this);
        card.setBackground(glass(GLASS, 0, 12));
        card.setClipToOutline(true);

        ImageView art = new ImageView(this);
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        card.addView(art, matchParent());
        loadThumbnailInto(art, item.art);

        if (item.progress >= 0) {
            View track = new View(this);
            track.setBackgroundColor(0x66000000);
            FrameLayout.LayoutParams trackParams = new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(4));
            trackParams.gravity = Gravity.BOTTOM;
            card.addView(track, trackParams);

            View bar = new View(this);
            bar.setBackgroundColor(Color.WHITE);
            FrameLayout.LayoutParams barParams = new FrameLayout.LayoutParams(
                    dp(VIDEO_W * item.progress / 100f), dp(4));
            barParams.gravity = Gravity.BOTTOM | Gravity.START;
            card.addView(bar, barParams);
        }

        final View ring = new View(this);
        ring.setBackground(glass(0, Color.WHITE, 12, 2));
        ring.setVisibility(View.INVISIBLE);
        card.addView(ring, matchParent());

        tile.addView(card, new LinearLayout.LayoutParams(dp(VIDEO_W), dp(VIDEO_H)));

        final TextView title = new TextView(this);
        title.setText(item.title);
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setShadowLayer(dp(6), 0, dp(1), 0x99000000);
        title.setPadding(dp(2), dp(11), dp(2), 0);
        title.setAlpha(0.75f);
        tile.addView(title, new LinearLayout.LayoutParams(
                dp(VIDEO_W), ViewGroup.LayoutParams.WRAP_CONTENT));

        // Second line: the episode or channel, and for continue-watching the app it is in.
        String detail = item.subtitle;
        if (showAppName) {
            String appName = appLabel(item.packageName);
            if (!appName.isEmpty()) {
                detail = detail.isEmpty() ? appName : appName + "  -  " + detail;
            }
        }
        if (!detail.isEmpty()) {
            TextView second = new TextView(this);
            second.setText(detail);
            second.setTextColor(TEXT_DIM);
            second.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
            second.setSingleLine(true);
            second.setEllipsize(TextUtils.TruncateAt.END);
            second.setPadding(dp(2), dp(2), dp(2), 0);
            second.setAlpha(0.6f);
            tile.addView(second, new LinearLayout.LayoutParams(
                    dp(VIDEO_W), ViewGroup.LayoutParams.WRAP_CONTENT));
        }

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
        tile.setOnClickListener(v -> openProgram(item));
        return tile;
    }

    private String appLabel(String packageName) {
        for (Apps.Entry entry : apps) {
            if (entry.packageName().equals(packageName)) {
                return entry.label;
            }
        }
        return "";
    }

    /** Opens an entry using the link its app supplied, which lands on that exact title. */
    private void openProgram(TvFeed.Item item) {
        try {
            if (!item.intentUri.isEmpty()) {
                Intent intent = Intent.parseUri(item.intentUri, Intent.URI_INTENT_SCHEME);
                // A link with no target goes to the app that published it.
                if (intent.getComponent() == null && intent.getPackage() == null) {
                    intent.setPackage(item.packageName);
                }
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(intent);
                return;
            }
        } catch (Exception e) {
            // Fall through to opening the app itself.
        }
        Intent fallback = getPackageManager().getLeanbackLaunchIntentForPackage(item.packageName);
        if (fallback == null) {
            fallback = getPackageManager().getLaunchIntentForPackage(item.packageName);
        }
        try {
            if (fallback != null) {
                startActivity(fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } else {
                toast("That app could not be opened");
            }
        } catch (RuntimeException e) {
            toast("That app could not be opened");
        }
    }

    // ------------------------------------------------------------------
    // All apps panel
    // ------------------------------------------------------------------

    private boolean isOverlayOpen() {
        return isAllAppsOpen() || isSettingsOpen() || isThemePickerOpen();
    }

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

        if (!reorderable) {
            names.add("Hide from All Apps");
            actions.add(() -> {
                List<String> hidden = hiddenApps();
                if (!hidden.contains(entry.key)) {
                    hidden.add(entry.key);
                }
                prefs.saveText(PREF_HIDDEN_APPS, TextUtils.join("\n", hidden));
                renderRecents();
                renderAllApps();
                toast(entry.label + " hidden. Customize can bring it back.");
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
    // Customize screen
    // ------------------------------------------------------------------

    private boolean isSettingsOpen() {
        return settingsOverlay.getVisibility() == View.VISIBLE;
    }

    private List<String> hiddenApps() {
        List<String> hidden = new ArrayList<>();
        for (String key : prefs.text(PREF_HIDDEN_APPS).split("\n")) {
            if (!key.isEmpty() && !hidden.contains(key)) {
                hidden.add(key);
            }
        }
        return hidden;
    }

    /**
     * Shows the Customize screen. It is rebuilt every time something changes,
     * so each line always shows the current value.
     *
     * @param focusIndex which line to put the remote on
     */
    private void openSettings(int focusIndex) {
        home.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        settingsOverlay.removeAllViews();

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackground(glass(0x33FFFFFF, GLASS_EDGE, 28));
        panel.setPadding(dp(22), dp(18), dp(22), dp(12));

        TextView title = new TextView(this);
        title.setText("Customize");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        title.setPadding(dp(8), 0, 0, dp(8));
        panel.addView(title);

        final LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(dp(4), dp(4), dp(4), dp(10));
        list.setClipChildren(false);
        list.setClipToPadding(false);

        int index = prefs.palette();
        if (index < 0 || index >= GradientView.PALETTES.length) {
            index = 0;
        }
        addSettingsHeading(list, "Look");
        addSettingsLine(list, "Theme", GradientView.PALETTES[index].name, this::openThemePicker);
        addSettingsLine(list, "Background motion", prefs.motion() ? "On" : "Off", () -> {
            boolean enabled = !prefs.motion();
            prefs.saveMotion(enabled);
            background.setMotion(enabled);
        });

        addSettingsHeading(list, "Rows on the home screen");
        final List<String> order = rowOrder();
        for (final String id : order) {
            final RowSection section = sectionById(id);
            if (section == null) {
                continue;
            }
            String state = rowEnabled(section) ? "Shown" : "Hidden";
            addSettingsLine(list, section.settingsName, state,
                    () -> showRowMenu(section, order));
        }

        addSettingsHeading(list, "Apps");
        final int hiddenCount = hiddenApps().size();
        addSettingsLine(list, "Hidden apps",
                hiddenCount == 0 ? "None" : hiddenCount + " hidden, press OK to show again",
                () -> {
                    if (hiddenCount == 0) {
                        toast("To hide one: All Apps, hold OK on the app, Hide");
                    } else {
                        prefs.saveText(PREF_HIDDEN_APPS, "");
                        renderRecents();
                        renderAllApps();
                    }
                });

        addSettingsHeading(list, "TV");
        addSettingsLine(list, "Mute Disney+ and Hulu ads (experimental)",
                isAdMuterOn() ? "On" : "Off", this::toggleAdMuter);
        addSettingsLine(list, "Glass Home screensaver",
                isOurScreensaver() ? "On" : "Off", this::toggleScreensaver);

        addSettingsHeading(list, "About");
        boolean newer = prefs.time(PREF_UPDATE_CODE) > Updater.installedCode(this);
        addSettingsLine(list, "Glass Home " + Updater.installedName(this),
                newer ? "Update available, press OK" : "Check for updates",
                () -> startUpdateCheck(true));

        ScrollView scroll = new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(list, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        panel.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        FrameLayout.LayoutParams panelParams = new FrameLayout.LayoutParams(
                dp(600), ViewGroup.LayoutParams.MATCH_PARENT);
        panelParams.gravity = Gravity.CENTER_HORIZONTAL;
        panelParams.setMargins(0, dp(30), 0, dp(30));
        settingsOverlay.addView(panel, panelParams);
        settingsOverlay.setVisibility(View.VISIBLE);

        // Put the remote back on the line that was just used.
        List<View> lines = new ArrayList<>();
        for (int i = 0; i < list.getChildCount(); i++) {
            if (list.getChildAt(i).isFocusable()) {
                lines.add(list.getChildAt(i));
            }
        }
        if (!lines.isEmpty()) {
            final View target = lines.get(Math.max(0, Math.min(focusIndex, lines.size() - 1)));
            target.post(target::requestFocus);
        }
    }

    private void closeSettings() {
        if (!isSettingsOpen()) {
            return;
        }
        settingsOverlay.setVisibility(View.GONE);
        settingsOverlay.removeAllViews();
        home.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
        goToTop();
    }

    private void addSettingsHeading(LinearLayout list, String text) {
        TextView heading = new TextView(this);
        heading.setText(text);
        heading.setTextColor(TEXT_DIM);
        heading.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        heading.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        heading.setLetterSpacing(0.08f);
        heading.setPadding(dp(10), dp(14), 0, dp(4));
        list.addView(heading);
    }

    /** One line on the Customize screen: a name on the left, its current value on the right. */
    private void addSettingsLine(final LinearLayout list, String label, String value,
            final Runnable action) {
        final LinearLayout line = new LinearLayout(this);
        line.setOrientation(LinearLayout.HORIZONTAL);
        line.setGravity(Gravity.CENTER_VERTICAL);
        line.setPadding(dp(16), dp(11), dp(16), dp(11));
        line.setBackground(glass(0x14FFFFFF, 0, 14));
        line.setFocusable(true);
        line.setClickable(true);

        final TextView name = new TextView(this);
        name.setText(label);
        name.setTextColor(Color.WHITE);
        name.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        line.addView(name, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        final TextView state = new TextView(this);
        state.setText(value);
        state.setTextColor(TEXT_DIM);
        state.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        state.setPadding(dp(12), 0, 0, 0);
        line.addView(state);

        line.setOnFocusChangeListener((v, focused) -> {
            line.setBackground(focused
                    ? glass(0xF2FFFFFF, Color.WHITE, 14) : glass(0x14FFFFFF, 0, 14));
            name.setTextColor(focused ? 0xFF101014 : Color.WHITE);
            state.setTextColor(focused ? 0xFF404048 : TEXT_DIM);
        });
        line.setOnClickListener(v -> {
            // Work out which line this is, so the remote can be put back on it.
            int position = 0;
            for (int i = 0; i < list.getChildCount(); i++) {
                View child = list.getChildAt(i);
                if (child == line) {
                    break;
                }
                if (child.isFocusable()) {
                    position++;
                }
            }
            action.run();
            // Actions that open something else (the theme picker, a dialog) redraw later.
            if (isSettingsOpen() && !isThemePickerOpen()) {
                openSettings(position);
            }
        });

        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.setMargins(0, dp(3), 0, dp(3));
        list.addView(line, params);
    }

    /** Show, hide or move one home-screen row. */
    private void showRowMenu(final RowSection section, final List<String> order) {
        final int position = order.indexOf(section.id);
        final List<String> names = new ArrayList<>();
        final List<Runnable> actions = new ArrayList<>();

        if (section != favorites) {
            final boolean shown = rowEnabled(section);
            names.add(shown ? "Hide this row" : "Show this row");
            actions.add(() -> prefs.saveFlag(PREF_ROW_HIDDEN + section.id, shown));
        }
        if (position > 0) {
            names.add("Move up");
            actions.add(() -> {
                order.remove(position);
                order.add(position - 1, section.id);
                prefs.saveText(PREF_ROW_ORDER, TextUtils.join(",", order));
            });
        }
        if (position >= 0 && position < order.size() - 1) {
            names.add("Move down");
            actions.add(() -> {
                order.remove(position);
                order.add(position + 1, section.id);
                prefs.saveText(PREF_ROW_ORDER, TextUtils.join(",", order));
            });
        }

        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle(section.settingsName)
                .setItems(names.toArray(new String[0]), (dialog, which) -> {
                    actions.get(which).run();
                    applyRowOrder();
                    // The row keeps its place in the list unless it was moved.
                    int line = 2 + rowOrder().indexOf(section.id);
                    openSettings(line);
                })
                .show();
    }

    // --- Things that change a system setting. They need a permission the PC
    // --- tool grants (option 5); without it they explain what to do.

    private static final String AD_MUTER =
            "tv.glasshome.launcher/tv.glasshome.launcher.AdMuteService";
    private static final String SCREENSAVER =
            "tv.glasshome.launcher/tv.glasshome.launcher.ClockDream";

    private static boolean sameComponent(String a, String b) {
        ComponentName first = a == null ? null : ComponentName.unflattenFromString(a.trim());
        ComponentName second = b == null ? null : ComponentName.unflattenFromString(b.trim());
        return first != null && first.equals(second);
    }

    private String secureSetting(String name) {
        try {
            String value = Settings.Secure.getString(getContentResolver(), name);
            return value == null ? "" : value;
        } catch (RuntimeException e) {
            return "";
        }
    }

    private boolean writeSecureSetting(String name, String value) {
        try {
            return Settings.Secure.putString(getContentResolver(), name, value);
        } catch (RuntimeException e) {
            toast("Not allowed yet. Run the PC tool and choose option 5 once.");
            return false;
        }
    }

    private boolean isAdMuterOn() {
        for (String service : secureSetting("enabled_accessibility_services").split(":")) {
            if (sameComponent(service, AD_MUTER)) {
                return true;
            }
        }
        return false;
    }

    private void toggleAdMuter() {
        boolean turnOn = !isAdMuterOn();
        List<String> services = new ArrayList<>();
        for (String service : secureSetting("enabled_accessibility_services").split(":")) {
            if (!service.isEmpty() && !sameComponent(service, AD_MUTER)) {
                services.add(service);
            }
        }
        if (turnOn) {
            services.add(AD_MUTER);
        }
        if (writeSecureSetting("enabled_accessibility_services", TextUtils.join(":", services))
                && turnOn) {
            writeSecureSetting("accessibility_enabled", "1");
        }
    }

    private boolean isOurScreensaver() {
        return sameComponent(secureSetting("screensaver_components"), SCREENSAVER);
    }

    private void toggleScreensaver() {
        if (isOurScreensaver()) {
            // Put back whatever was there before this was turned on.
            writeSecureSetting("screensaver_components", prefs.text(PREF_SCREENSAVER_BEFORE));
        } else {
            String before = secureSetting("screensaver_components");
            if (writeSecureSetting("screensaver_components", SCREENSAVER)) {
                prefs.saveText(PREF_SCREENSAVER_BEFORE, before);
                writeSecureSetting("screensaver_enabled", "1");
            }
        }
    }

    // ------------------------------------------------------------------
    // Theme picker
    // ------------------------------------------------------------------

    private boolean isThemePickerOpen() {
        return themeOverlay.getVisibility() == View.VISIBLE;
    }

    /**
     * A grid with a small preview of every theme. Moving onto one shows it
     * full-screen behind the grid; OK keeps it, Back returns to the old one.
     */
    private void openThemePicker() {
        themeOverlay.removeAllViews();

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setBackground(glass(0x29FFFFFF, GLASS_EDGE, 28));
        panel.setPadding(dp(20), dp(18), dp(20), dp(8));
        panel.setClipChildren(false);

        TextView title = new TextView(this);
        title.setText("Theme");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        title.setPadding(dp(14), 0, 0, dp(4));
        panel.addView(title);

        GridLayout grid = new GridLayout(this);
        grid.setColumnCount(GRID_COLUMNS);
        grid.setClipChildren(false);
        grid.setClipToPadding(false);
        grid.setPadding(dp(6), dp(12), dp(6), dp(16));

        int current = prefs.palette();
        View toFocus = null;
        for (int i = 0; i < GradientView.PALETTES.length; i++) {
            View tile = makeThemeTile(i);
            GridLayout.LayoutParams params = new GridLayout.LayoutParams();
            params.setMargins(dp(9), dp(8), dp(9), dp(10));
            grid.addView(tile, params);
            if (i == current || toFocus == null) {
                toFocus = tile;
            }
        }

        ScrollView scroll = new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setClipChildren(false);
        scroll.setClipToPadding(false);
        FrameLayout.LayoutParams gridParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        gridParams.gravity = Gravity.CENTER_HORIZONTAL;
        scroll.addView(grid, gridParams);
        panel.addView(scroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        FrameLayout.LayoutParams panelParams = matchParent();
        panelParams.setMargins(dp(36), dp(30), dp(36), dp(30));
        themeOverlay.addView(panel, panelParams);

        // The Customize screen steps aside so the preview behind is visible.
        settingsOverlay.setVisibility(View.GONE);
        themeOverlay.setVisibility(View.VISIBLE);
        if (toFocus != null) {
            final View target = toFocus;
            target.post(target::requestFocus);
        }
    }

    private View makeThemeTile(final int index) {
        final LinearLayout tile = new LinearLayout(this);
        tile.setOrientation(LinearLayout.VERTICAL);
        tile.setGravity(Gravity.CENTER_HORIZONTAL);
        tile.setClipChildren(false);
        tile.setClipToPadding(false);
        tile.setFocusable(true);
        tile.setClickable(true);

        final FrameLayout card = new FrameLayout(this);
        card.setBackground(glass(0xFF000000, 0, 14));
        card.setClipToOutline(true);

        GradientView preview = new GradientView(this);
        preview.setPalette(index);
        preview.setMotion(false);
        card.addView(preview, matchParent());

        final View ring = new View(this);
        ring.setBackground(glass(0, Color.WHITE, 14, 2));
        ring.setVisibility(View.INVISIBLE);
        card.addView(ring, matchParent());

        // A fainter edge all the time, so the darkest themes still read as tiles.
        View edge = new View(this);
        edge.setBackground(glass(0, GLASS_EDGE, 14));
        card.addView(edge, matchParent());

        tile.addView(card, new LinearLayout.LayoutParams(dp(GRID_W), dp(GRID_H)));

        final TextView label = new TextView(this);
        label.setText(GradientView.PALETTES[index].name
                + (index == prefs.palette() ? "  (current)" : ""));
        label.setTextColor(Color.WHITE);
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        label.setSingleLine(true);
        label.setGravity(Gravity.CENTER);
        label.setPadding(0, dp(12), 0, 0);
        label.setAlpha(0.6f);
        tile.addView(label, new LinearLayout.LayoutParams(
                dp(GRID_W), ViewGroup.LayoutParams.WRAP_CONTENT));

        tile.setOnFocusChangeListener((v, focused) -> {
            float scale = focused ? FOCUS_SCALE : 1f;
            card.animate().scaleX(scale).scaleY(scale).setDuration(ANIM_MS).start();
            card.setTranslationZ(focused ? dp(10) : 0);
            ring.setVisibility(focused ? View.VISIBLE : View.INVISIBLE);
            label.animate().alpha(focused ? 1f : 0.6f).setDuration(ANIM_MS).start();
            if (focused) {
                background.setPalette(index); // Live preview behind the grid.
            }
        });
        tile.setOnClickListener(v -> {
            prefs.savePalette(index);
            closeThemePicker(true);
        });
        return tile;
    }

    /** Closes the picker and puts the saved theme back on screen. */
    private void closeThemePicker(boolean backToSettings) {
        if (!isThemePickerOpen()) {
            return;
        }
        themeOverlay.setVisibility(View.GONE);
        themeOverlay.removeAllViews();
        background.setPalette(prefs.palette());
        if (backToSettings) {
            openSettings(0);
        }
    }

    // ------------------------------------------------------------------
    // Self-update
    // ------------------------------------------------------------------

    /** Looks for a newer build at most twice a day, without bothering the viewer. */
    private void checkForUpdateQuietly() {
        if (System.currentTimeMillis() - prefs.time(PREF_UPDATE_CHECKED) < UPDATE_CHECK_MS) {
            return;
        }
        startUpdateCheck(false);
    }

    /**
     * Asks GitHub for the newest version.
     *
     * @param askedFor true when the viewer pressed the button, so every outcome is reported
     */
    private void startUpdateCheck(final boolean askedFor) {
        if (updateBusy || network.isShutdown()) {
            return;
        }
        updateBusy = true;
        if (askedFor) {
            toast("Checking for updates...");
        }
        network.execute(() -> {
            Updater.Release found = null;
            String error = null;
            try {
                found = Updater.latest();
            } catch (Exception e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            final Updater.Release release = found;
            final String problem = error;
            runOnUiThread(() -> {
                updateBusy = false;
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                if (release == null) {
                    if (askedFor) {
                        toast("Could not check for updates: " + problem);
                    }
                    return;
                }
                prefs.saveTime(PREF_UPDATE_CHECKED, System.currentTimeMillis());
                prefs.saveTime(PREF_UPDATE_CODE, release.versionCode);
                boolean newer = release.versionCode > Updater.installedCode(this);
                updateButton.setVisibility(newer ? View.VISIBLE : View.GONE);
                if (!askedFor) {
                    return;
                }
                if (newer) {
                    offerUpdate(release);
                } else {
                    toast("Glass Home " + Updater.installedName(this) + " is the latest version");
                }
            });
        });
    }

    private void offerUpdate(final Updater.Release release) {
        String message = "You have " + Updater.installedName(this) + "."
                + (release.notes.isEmpty() ? "" : "\n\nWhat's new: " + release.notes)
                + "\n\nYour favorites and settings are kept.";
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("Glass Home " + release.versionName + " is available")
                .setMessage(message)
                .setPositiveButton("Install", (dialog, which) -> downloadAndInstall(release))
                .setNegativeButton("Not now", null)
                .show();
    }

    private void downloadAndInstall(final Updater.Release release) {
        if (updateBusy || network.isShutdown()) {
            return;
        }
        if (!getPackageManager().canRequestPackageInstalls()) {
            // Android has to be told once that this app may install its own updates.
            try {
                startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.fromParts("package", getPackageName(), null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                toast("Allow Glass Home here, then press Update again");
            } catch (RuntimeException e) {
                toast("Run the PC tool and choose option 5 once to allow self-updates");
            }
            return;
        }
        updateBusy = true;
        toast("Downloading the update...");
        network.execute(() -> {
            String error = null;
            try {
                File apk = Updater.download(MainActivity.this, release);
                Updater.install(MainActivity.this, apk);
            } catch (Exception e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            final String problem = error;
            runOnUiThread(() -> {
                updateBusy = false;
                if (problem != null) {
                    toast("Update failed: " + problem);
                }
            });
        });
    }

    /**
     * Handles the installer's reply. Returns true if the intent was one.
     * Android first asks for the viewer's confirmation; a successful install
     * then restarts the app by itself.
     */
    private boolean handleInstallStatus(Intent intent) {
        if (intent == null || !Updater.ACTION_INSTALL_STATUS.equals(intent.getAction())) {
            return false;
        }
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) {
                try {
                    startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                } catch (RuntimeException e) {
                    toast("The install screen could not be opened");
                }
            }
        } else if (status != PackageInstaller.STATUS_SUCCESS) {
            String message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
            toast("Update was not installed" + (message == null ? "" : ": " + message));
        }
        // The same intent must not be acted on again if the screen is rebuilt.
        intent.setAction(Intent.ACTION_MAIN);
        return true;
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
