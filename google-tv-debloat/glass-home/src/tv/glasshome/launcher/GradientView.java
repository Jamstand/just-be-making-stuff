package tv.glasshome.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.Shader;
import android.os.SystemClock;
import android.view.View;

import java.util.Random;

/**
 * Full-screen background: four soft colour glows, one per corner region,
 * drifting slowly over a near-black base. It is painted into a small bitmap
 * and stretched to the screen, which keeps it cheap on a TV chip. A faint
 * film-grain layer on top stops the smooth shading from showing as stripes.
 */
public class GradientView extends View {

    /** One background style. An empty blob list means a plain dark screen. */
    public static final class Palette {
        final String name;
        final int base;
        final int[] blobs;
        /** How strongly the glows show, 0 to 255. Lower is darker and calmer. */
        final int strength;

        Palette(String name, int base, int... blobs) {
            this(name, GLOW_ALPHA, base, blobs);
        }

        Palette(String name, int strength, int base, int[] blobs) {
            this.name = name;
            this.strength = strength;
            this.base = base;
            this.blobs = blobs;
        }

        /** A dark one-colour theme: four shades of the same hue over near-black. */
        static Palette mono(String name, int base, int... shades) {
            return new Palette(name, MONO_ALPHA, base, shades);
        }
    }

    public static final Palette[] PALETTES = {
        new Palette("Midnight", 0xFF04040C, 0xFF2A1FA8, 0xFF6A1FB0, 0xFF0A6F7A, 0xFF16307F),
        new Palette("Ember",    0xFF0A0304, 0xFFA01A40, 0xFFC4521F, 0xFF4E1560, 0xFF7A1230),
        new Palette("Ocean",    0xFF02080F, 0xFF0A5494, 0xFF0E8C9C, 0xFF0F327A, 0xFF086C60),
        new Palette("Forest",   0xFF020A07, 0xFF0C6C40, 0xFF178878, 0xFF275218, 0xFF094450),
        new Palette("Graphite", 0xFF060607, 0xFF34343E, 0xFF252A34, 0xFF423E48, 0xFF1B202A),
        new Palette("Pure Dark", 0xFF030304),
        // Monotone themes: one hue each, darker and quieter than the ones above.
        Palette.mono("Mono Slate",  0xFF030405, 0xFF2C3A4E, 0xFF1C2838, 0xFF3A4960, 0xFF141C28),
        Palette.mono("Mono Indigo", 0xFF030308, 0xFF2A2470, 0xFF1A1650, 0xFF393290, 0xFF12103A),
        Palette.mono("Mono Wine",   0xFF060203, 0xFF5C1630, 0xFF3E0E22, 0xFF741E3E, 0xFF2A0916),
        Palette.mono("Mono Moss",   0xFF020503, 0xFF1E4A30, 0xFF123522, 0xFF2A5E3E, 0xFF0C2618),
        Palette.mono("Mono Teal",   0xFF020506, 0xFF104A54, 0xFF0A353E, 0xFF18606C, 0xFF07262C),
        Palette.mono("Mono Bronze", 0xFF060402, 0xFF5A3A16, 0xFF3E270E, 0xFF70491E, 0xFF2A1A09),
        Palette.mono("Mono Ash",    0xFF040404, 0xFF303033, 0xFF202022, 0xFF3C3C40, 0xFF161618),
    };

    private static final int BUF_W = 320;
    private static final int BUF_H = 180;
    // The drift is very slow, so 15 frames a second looks the same and leaves
    // the TV's processor free for the remote.
    private static final long FRAME_MS = 66;

    // Each glow has a home position (as a fraction of the screen) and wanders a
    // little around it. Keeping them apart is what stops the colours merging
    // into one flat wash, and leaves dark space between them.
    private static final float[] HOME_X = {0.20f, 0.82f, 0.72f, 0.24f};
    private static final float[] HOME_Y = {0.24f, 0.20f, 0.84f, 0.80f};
    private static final float WANDER = 0.13f;
    // Drift speeds in radians per second: a full cycle takes a few minutes.
    private static final float[] SPEED_X = {0.031f, 0.023f, 0.041f, 0.017f};
    private static final float[] SPEED_Y = {0.019f, 0.037f, 0.013f, 0.029f};
    private static final float[] PHASE_X = {0.0f, 2.1f, 4.2f, 1.3f};
    private static final float[] PHASE_Y = {1.7f, 0.4f, 3.3f, 5.1f};
    // Glow size as a fraction of the screen width.
    private static final float[] RADIUS  = {0.46f, 0.42f, 0.44f, 0.38f};
    private static final int GLOW_ALPHA = 0xB0;
    private static final int MONO_ALPHA = 0x96;
    private static final int GRAIN_SIZE = 128;

    private final Bitmap buffer = Bitmap.createBitmap(BUF_W, BUF_H, Bitmap.Config.ARGB_8888);
    private final Canvas bufferCanvas = new Canvas(buffer);
    private final Paint blobPaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint outPaint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.DITHER_FLAG);
    private final Paint shadePaint = new Paint(Paint.DITHER_FLAG);
    private final Paint grainPaint = new Paint();
    private final Matrix matrix = new Matrix();
    private final Rect dst = new Rect();

    private Palette palette = PALETTES[0];
    private RadialGradient[] shaders = new RadialGradient[0];
    private boolean motion = true;
    private boolean running = false;
    private float frozenTime = 40f;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (running && motion) {
                invalidate();
                postDelayed(this, FRAME_MS);
            }
        }
    };

    public GradientView(Context context) {
        super(context);
        setPalette(0);
        shadePaint.setShader(new LinearGradient(0f, 0f, 0f, BUF_H,
                new int[] {0x59000000, 0x0D000000, 0x73000000},
                new float[] {0f, 0.45f, 1f}, Shader.TileMode.CLAMP));

        // Film grain: random specks, a few percent visible. On an 8-bit screen
        // a dark gradient only has a handful of brightness steps, which show
        // as stripes; the grain breaks those edges up.
        Bitmap grain = Bitmap.createBitmap(GRAIN_SIZE, GRAIN_SIZE, Bitmap.Config.ARGB_8888);
        int[] pixels = new int[GRAIN_SIZE * GRAIN_SIZE];
        Random random = new Random(7);
        for (int i = 0; i < pixels.length; i++) {
            int alpha = random.nextInt(11);
            int shade = random.nextBoolean() ? 0xFFFFFF : 0x000000;
            pixels[i] = (alpha << 24) | shade;
        }
        grain.setPixels(pixels, 0, GRAIN_SIZE, 0, 0, GRAIN_SIZE, GRAIN_SIZE);
        grainPaint.setShader(new BitmapShader(grain, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT));
    }

    public void setPalette(int index) {
        if (index < 0 || index >= PALETTES.length) {
            index = 0;
        }
        palette = PALETTES[index];
        shaders = new RadialGradient[palette.blobs.length];
        for (int i = 0; i < shaders.length; i++) {
            int rgb = palette.blobs[i] & 0x00FFFFFF;
            // Bright in the middle, fading out gently so the edge is never visible.
            shaders[i] = new RadialGradient(0f, 0f, 1f,
                    new int[] {
                        (palette.strength << 24) | rgb,
                        ((palette.strength * 2 / 5) << 24) | rgb,
                        ((palette.strength / 10) << 24) | rgb,
                        rgb,
                    },
                    new float[] {0f, 0.45f, 0.8f, 1f}, Shader.TileMode.CLAMP);
        }
        invalidate();
    }

    /** Turn the slow drift on or off. Off leaves a still gradient. */
    public void setMotion(boolean enabled) {
        if (motion && !enabled) {
            frozenTime = now();
        }
        motion = enabled;
        restartTicker();
        invalidate();
    }

    /** Called by the activity so nothing animates while the launcher is hidden. */
    public void setRunning(boolean enabled) {
        running = enabled;
        restartTicker();
    }

    private void restartTicker() {
        removeCallbacks(tick);
        if (running && motion) {
            post(tick);
        }
    }

    private static float now() {
        return SystemClock.uptimeMillis() / 1000f;
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldW, int oldH) {
        dst.set(0, 0, w, h);
    }

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(tick);
        super.onDetachedFromWindow();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        float t = motion ? now() : frozenTime;

        bufferCanvas.drawColor(palette.base);
        for (int i = 0; i < shaders.length; i++) {
            int k = i % HOME_X.length;
            float cx = BUF_W * (HOME_X[k] + WANDER * (float) Math.sin(t * SPEED_X[k] + PHASE_X[k]));
            float cy = BUF_H * (HOME_Y[k] + WANDER * (float) Math.cos(t * SPEED_Y[k] + PHASE_Y[k]));
            float r = BUF_W * RADIUS[k];
            matrix.setScale(r, r);
            matrix.postTranslate(cx, cy);
            shaders[i].setLocalMatrix(matrix);
            blobPaint.setShader(shaders[i]);
            bufferCanvas.drawRect(0f, 0f, BUF_W, BUF_H, blobPaint);
        }
        // Darken the top and bottom a little so white text stays readable.
        bufferCanvas.drawRect(0f, 0f, BUF_W, BUF_H, shadePaint);

        canvas.drawBitmap(buffer, null, dst, outPaint);
        canvas.drawRect(dst, grainPaint);
    }
}
