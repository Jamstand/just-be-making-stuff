package tv.glasshome.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Rect;
import android.graphics.Shader;
import android.os.SystemClock;
import android.view.View;

/**
 * Full-screen background: a few large soft colour blobs drifting slowly over a
 * dark base. It is painted into a tiny bitmap and stretched to the screen,
 * which is what gives the soft, blurred look and keeps it cheap on a TV chip.
 */
public class GradientView extends View {

    /** One background style. An empty blob list means a plain dark screen. */
    public static final class Palette {
        final String name;
        final int base;
        final int[] blobs;

        Palette(String name, int base, int... blobs) {
            this.name = name;
            this.base = base;
            this.blobs = blobs;
        }
    }

    public static final Palette[] PALETTES = {
        new Palette("Midnight", 0xFF07071A, 0xFF3B2FBF, 0xFF7A2CBF, 0xFF0E7C86, 0xFF1B3A8F),
        new Palette("Ember",    0xFF140608, 0xFFB3204A, 0xFFD9622B, 0xFF5B1A6E, 0xFF8A1538),
        new Palette("Ocean",    0xFF03101C, 0xFF0B5FA5, 0xFF11A0B0, 0xFF123C8C, 0xFF0A7D6E),
        new Palette("Forest",   0xFF04120C, 0xFF0F7A4A, 0xFF1C9C8A, 0xFF2E5E1E, 0xFF0C4F5C),
        new Palette("Graphite", 0xFF0B0B0D, 0xFF3A3A44, 0xFF2A2F3A, 0xFF4A4550, 0xFF1F2530),
        new Palette("Pure Dark", 0xFF050506),
    };

    private static final int BUF_W = 160;
    private static final int BUF_H = 90;
    private static final long FRAME_MS = 40;

    // Per-blob drift speeds (radians per second) and starting offsets.
    // Full cycles take a few minutes, so the motion is barely noticeable.
    private static final float[] SPEED_X = {0.031f, 0.023f, 0.041f, 0.017f};
    private static final float[] SPEED_Y = {0.019f, 0.037f, 0.013f, 0.029f};
    private static final float[] PHASE_X = {0.0f, 2.1f, 4.2f, 1.3f};
    private static final float[] PHASE_Y = {1.7f, 0.4f, 3.3f, 5.1f};
    private static final float[] RADIUS  = {0.75f, 0.65f, 0.70f, 0.60f};

    private final Bitmap buffer = Bitmap.createBitmap(BUF_W, BUF_H, Bitmap.Config.ARGB_8888);
    private final Canvas bufferCanvas = new Canvas(buffer);
    private final Paint blobPaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.DITHER_FLAG);
    private final Paint outPaint = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.DITHER_FLAG);
    private final Paint shadePaint = new Paint(Paint.DITHER_FLAG);
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
    }

    public void setPalette(int index) {
        if (index < 0 || index >= PALETTES.length) {
            index = 0;
        }
        palette = PALETTES[index];
        shaders = new RadialGradient[palette.blobs.length];
        for (int i = 0; i < shaders.length; i++) {
            int color = (palette.blobs[i] & 0x00FFFFFF) | 0xD0000000;
            shaders[i] = new RadialGradient(0f, 0f, 1f,
                    new int[] {color, color & 0x00FFFFFF}, null, Shader.TileMode.CLAMP);
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
        // Darken the top and bottom a little so white text stays readable.
        shadePaint.setShader(new LinearGradient(0f, 0f, 0f, h,
                new int[] {0x66000000, 0x14000000, 0x8C000000},
                new float[] {0f, 0.45f, 1f}, Shader.TileMode.CLAMP));
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
            int k = i % SPEED_X.length;
            float cx = BUF_W * (0.5f + 0.45f * (float) Math.sin(t * SPEED_X[k] + PHASE_X[k]));
            float cy = BUF_H * (0.5f + 0.45f * (float) Math.cos(t * SPEED_Y[k] + PHASE_Y[k]));
            float r = BUF_W * RADIUS[k];
            matrix.setScale(r, r);
            matrix.postTranslate(cx, cy);
            shaders[i].setLocalMatrix(matrix);
            blobPaint.setShader(shaders[i]);
            bufferCanvas.drawRect(0f, 0f, BUF_W, BUF_H, blobPaint);
        }

        canvas.drawBitmap(buffer, null, dst, outPaint);
        canvas.drawRect(dst, shadePaint);
    }
}
