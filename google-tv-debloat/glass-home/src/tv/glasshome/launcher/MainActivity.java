package tv.glasshome.launcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
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
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The home screen: clock, quick buttons, a favorites row, and an "all apps"
 * panel. Everything is built in code, with no layout files.
 */
public class MainActivity extends Activity {

    // Sizes in dp. A TV screen is 960 x 540 dp.
    private static final int SIDE_MARGIN = 48;
    private static final int FAV_W = 176;
    private static final int FAV_H = 99;
    private static final int GRID_W = 150;
    private static final int GRID_H = 84;
    private static final int GRID_COLUMNS = 5;
    private static final float FOCUS_SCALE = 1.12f;

    private static final int GLASS = 0x24FFFFFF;
    private static final int GLASS_EDGE = 0x38FFFFFF;
    private static final int TEXT_DIM = 0xB3FFFFFF;

    private Apps.Prefs prefs;
    private GradientView background;
    private LinearLayout home;
    private LinearLayout favoritesRow;
    private HorizontalScrollView favoritesScroll;
    private TextView emptyHint;
    private FrameLayout allAppsOverlay;
    private ScrollView allAppsScroll;
    private GridLayout allAppsGrid;
    private TextView backgroundButton;
    private TextView motionButton;

    private List<Apps.Entry> apps = new ArrayList<>();
    private String appsSignature = null;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();

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
        super.onDestroy();
    }

    /** Home button pressed while the launcher is already on screen. */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (hasWindowFocus()) {
            closeAllApps();
            favoritesScroll.scrollTo(0, 0);
            if (favoritesRow.getChildCount() > 0) {
                favoritesRow.getChildAt(0).requestFocus();
            }
        }
    }

    @Override
    public void onBackPressed() {
        // A home screen has nowhere to go back to; Back only closes the apps panel.
        if (isAllAppsOpen()) {
            closeAllApps();
        }
    }

    // ------------------------------------------------------------------
    // Building the screen
    // ------------------------------------------------------------------

    private View buildHome() {
        home = new LinearLayout(this);
        home.setOrientation(LinearLayout.VERTICAL);
        home.setClipChildren(false);
        home.setClipToPadding(false);

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

        // Empty space in the middle so the background can breathe.
        home.addView(new View(this), new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        TextView favoritesTitle = new TextView(this);
        favoritesTitle.setText("Favorites");
        favoritesTitle.setTextColor(TEXT_DIM);
        favoritesTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        favoritesTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        favoritesTitle.setLetterSpacing(0.08f);
        favoritesTitle.setPadding(dp(SIDE_MARGIN + 8), 0, 0, dp(2));
        home.addView(favoritesTitle);

        emptyHint = new TextView(this);
        emptyHint.setText("No favorites yet. Open All Apps, then hold OK on an app to add it.");
        emptyHint.setTextColor(TEXT_DIM);
        emptyHint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        emptyHint.setPadding(dp(SIDE_MARGIN + 8), dp(24), dp(SIDE_MARGIN), dp(60));
        emptyHint.setVisibility(View.GONE);
        home.addView(emptyHint);

        favoritesRow = new LinearLayout(this);
        favoritesRow.setOrientation(LinearLayout.HORIZONTAL);
        favoritesRow.setClipChildren(false);
        favoritesRow.setClipToPadding(false);
        // The side margin lives inside the row so tiles scroll edge to edge.
        favoritesRow.setPadding(dp(SIDE_MARGIN), dp(18), dp(SIDE_MARGIN), dp(4));

        favoritesScroll = new HorizontalScrollView(this);
        favoritesScroll.setHorizontalScrollBarEnabled(false);
        favoritesScroll.setClipChildren(false);
        favoritesScroll.setClipToPadding(false);
        favoritesScroll.setFillViewport(false);
        favoritesScroll.addView(favoritesRow, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        home.addView(favoritesScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView tip = new TextView(this);
        tip.setText("Hold OK on an app for options");
        tip.setTextColor(0x66FFFFFF);
        tip.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tip.setGravity(Gravity.END);
        tip.setPadding(dp(SIDE_MARGIN), dp(2), dp(SIDE_MARGIN), dp(22));
        home.addView(tip, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        return home;
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
                    .setDuration(140).start();
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
     */
    private View makeTile(final Apps.Entry entry, int widthDp, int heightDp,
            final boolean inFavoritesRow) {
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
        // Favorites hide the name until focused; the apps panel always shows it, dimmed.
        final float restingAlpha = inFavoritesRow ? 0f : 0.6f;
        label.setAlpha(restingAlpha);
        tile.addView(label, new LinearLayout.LayoutParams(
                dp(widthDp), ViewGroup.LayoutParams.WRAP_CONTENT));

        tile.setOnFocusChangeListener((v, focused) -> {
            float scale = focused ? FOCUS_SCALE : 1f;
            card.animate().scaleX(scale).scaleY(scale).setDuration(160).start();
            card.setTranslationZ(focused ? dp(10) : 0);
            ring.setVisibility(focused ? View.VISIBLE : View.INVISIBLE);
            label.animate().alpha(focused ? 1f : restingAlpha).setDuration(160).start();
        });
        tile.setOnClickListener(v -> launch(entry));
        tile.setOnLongClickListener(v -> {
            showAppMenu(entry, inFavoritesRow);
            return true;
        });
        tile.setOnKeyListener((v, keyCode, event) -> {
            if (keyCode == KeyEvent.KEYCODE_MENU && event.getAction() == KeyEvent.ACTION_UP) {
                showAppMenu(entry, inFavoritesRow);
                return true;
            }
            return false;
        });
        return tile;
    }

    // ------------------------------------------------------------------
    // App list
    // ------------------------------------------------------------------

    private void reloadApps() {
        if (worker.isShutdown()) {
            return;
        }
        worker.execute(() -> {
            final List<Apps.Entry> loaded = Apps.load(MainActivity.this);
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
        renderFavorites(focusedKey());
        renderAllApps();
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
        boolean rowHadFocus = favoritesRow.hasFocus();
        favoritesRow.removeAllViews();
        View toFocus = null;
        for (String key : prefs.favorites()) {
            Apps.Entry entry = Apps.find(apps, key);
            if (entry == null) {
                continue; // Uninstalled or disabled; keep it saved in case it comes back.
            }
            View tile = makeTile(entry, FAV_W, FAV_H, true);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            params.setMargins(dp(8), 0, dp(8), 0);
            favoritesRow.addView(tile, params);
            if (key.equals(focusKey)) {
                toFocus = tile;
            }
        }
        boolean empty = favoritesRow.getChildCount() == 0;
        emptyHint.setVisibility(empty ? View.VISIBLE : View.GONE);
        favoritesScroll.setVisibility(empty ? View.GONE : View.VISIBLE);

        if (isAllAppsOpen()) {
            return;
        }
        if (toFocus == null && !empty && (rowHadFocus || getCurrentFocus() == null)) {
            toFocus = favoritesRow.getChildAt(0);
        }
        if (toFocus != null) {
            final View target = toFocus;
            target.post(target::requestFocus);
        }
    }

    private void renderAllApps() {
        String focusKey = isAllAppsOpen() ? focusedKey() : null;
        allAppsGrid.removeAllViews();
        View toFocus = null;
        for (Apps.Entry entry : apps) {
            View tile = makeTile(entry, GRID_W, GRID_H, false);
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
        if (favoritesRow.getChildCount() > 0) {
            favoritesRow.getChildAt(0).requestFocus();
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
    private void showAppMenu(final Apps.Entry entry, boolean fromFavoritesRow) {
        final List<String> favorites = prefs.favorites();
        final int position = favorites.indexOf(entry.key);
        final List<String> names = new ArrayList<>();
        final List<Runnable> actions = new ArrayList<>();

        names.add("Open");
        actions.add(() -> launch(entry));

        if (position < 0) {
            names.add("Add to favorites");
            actions.add(() -> {
                favorites.add(entry.key);
                prefs.saveFavorites(favorites);
                renderFavorites(null);
                toast(entry.label + " added to favorites");
            });
        } else {
            if (fromFavoritesRow && position > 0) {
                names.add("Move left");
                actions.add(() -> moveFavorite(favorites, position, position - 1, entry.key));
            }
            if (fromFavoritesRow && position < favorites.size() - 1) {
                names.add("Move right");
                actions.add(() -> moveFavorite(favorites, position, position + 1, entry.key));
            }
            names.add("Remove from favorites");
            actions.add(() -> {
                favorites.remove(entry.key);
                prefs.saveFavorites(favorites);
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

    private void moveFavorite(List<String> favorites, int from, int to, String key) {
        String moved = favorites.remove(from);
        favorites.add(to, moved);
        prefs.saveFavorites(favorites);
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
