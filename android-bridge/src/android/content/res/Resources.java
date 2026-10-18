package android.content.res;

import android.util.DisplayMetrics;

/**
 * Minimal android.content.res.Resources stub.
 * 载荷（merge.ME.q 等）用它取 DisplayMetrics 做 dp→px 换算。
 */
public class Resources {

    private static final DisplayMetrics METRICS = new DisplayMetrics();

    public DisplayMetrics getDisplayMetrics() {
        return METRICS;
    }

    public String getString(int id) {
        return "";
    }

    public String getString(int id, Object... formatArgs) {
        return "";
    }

    public int getIdentifier(String name, String defType, String defPackage) {
        return 0;
    }

    public int getDimensionPixelSize(int id) {
        return 0;
    }

    public float getDimension(int id) {
        return 0f;
    }

    public static class NotFoundException extends RuntimeException {
        public NotFoundException() {
        }

        public NotFoundException(String name) {
            super(name);
        }
    }
}
