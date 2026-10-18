package android.graphics;

/**
 * Minimal android.graphics.Bitmap stub。
 */
public class Bitmap {

    public enum Config {
        ALPHA_8,
        RGB_565,
        ARGB_4444,
        ARGB_8888,
        RGBA_F16,
        HARDWARE
    }

    private int width;
    private int height;

    public static Bitmap createBitmap(int width, int height, Config config) {
        Bitmap b = new Bitmap();
        b.width = width;
        b.height = height;
        return b;
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }
}
