package tv.glasshome.launcher;

import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.service.dreams.DreamService;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextClock;

import java.util.Random;

/**
 * The screensaver: the same drifting gradient as the home screen with a large
 * clock. The clock moves to a new spot every minute so nothing stays lit in
 * one place on the panel.
 */
public class ClockDream extends DreamService {

    private static final long MOVE_EVERY_MS = 60 * 1000L;
    private static final long MOVE_DURATION_MS = 4000L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Random random = new Random();
    private GradientView background;
    private LinearLayout clock;

    private final Runnable moveClock = new Runnable() {
        @Override
        public void run() {
            if (clock != null && background != null && background.getWidth() > 0) {
                // Wander within the middle half of the screen.
                float rangeX = background.getWidth() * 0.25f;
                float rangeY = background.getHeight() * 0.25f;
                clock.animate()
                        .translationX((random.nextFloat() * 2f - 1f) * rangeX)
                        .translationY((random.nextFloat() * 2f - 1f) * rangeY)
                        .setDuration(MOVE_DURATION_MS).start();
            }
            handler.postDelayed(this, MOVE_EVERY_MS);
        }
    };

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        setInteractive(false); // Any button press ends the screensaver.
        setFullscreen(true);
        setScreenBright(false);

        Apps.Prefs prefs = new Apps.Prefs(this);
        FrameLayout root = new FrameLayout(this);

        background = new GradientView(this);
        background.setPalette(prefs.palette());
        background.setMotion(true); // Always moving here, whatever the home screen setting.
        root.addView(background, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        clock = new LinearLayout(this);
        clock.setOrientation(LinearLayout.VERTICAL);
        clock.setGravity(Gravity.CENTER_HORIZONTAL);

        TextClock time = new TextClock(this);
        time.setFormat12Hour("h:mm");
        time.setFormat24Hour("H:mm");
        time.setTextColor(Color.WHITE);
        time.setTextSize(TypedValue.COMPLEX_UNIT_SP, 96);
        time.setTypeface(Typeface.create("sans-serif-thin", Typeface.NORMAL));
        time.setIncludeFontPadding(false);
        time.setAlpha(0.9f);
        clock.addView(time);

        TextClock date = new TextClock(this);
        date.setFormat12Hour("EEEE, MMMM d");
        date.setFormat24Hour("EEEE, MMMM d");
        date.setTextColor(Color.WHITE);
        date.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        date.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        date.setAlpha(0.65f);
        clock.addView(date);

        FrameLayout.LayoutParams clockParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        clockParams.gravity = Gravity.CENTER;
        root.addView(clock, clockParams);

        setContentView(root);
    }

    @Override
    public void onDreamingStarted() {
        super.onDreamingStarted();
        if (background != null) {
            background.setRunning(true);
        }
        handler.postDelayed(moveClock, 2000L);
    }

    @Override
    public void onDreamingStopped() {
        handler.removeCallbacks(moveClock);
        if (background != null) {
            background.setRunning(false);
        }
        super.onDreamingStopped();
    }

    @Override
    public void onDetachedFromWindow() {
        handler.removeCallbacks(moveClock);
        super.onDetachedFromWindow();
    }
}
