package android.util;

/**
 * Minimal android.util.DisplayMetrics stub（1080p / mdpi 基准）。
 */
public class DisplayMetrics {

    public int widthPixels = 1920;
    public int heightPixels = 1080;
    public float density = 1.0f;
    public int densityDpi = 160;
    public float scaledDensity = 1.0f;
    public float xdpi = 160f;
    public float ydpi = 160f;

    public void setTo(DisplayMetrics o) {
        if (o == null) {
            return;
        }
        widthPixels = o.widthPixels;
        heightPixels = o.heightPixels;
        density = o.density;
        densityDpi = o.densityDpi;
        scaledDensity = o.scaledDensity;
        xdpi = o.xdpi;
        ydpi = o.ydpi;
    }

    public void setToDefaults() {
        widthPixels = 1920;
        heightPixels = 1080;
        density = 1.0f;
        densityDpi = 160;
        scaledDensity = 1.0f;
        xdpi = 160f;
        ydpi = 160f;
    }
}
