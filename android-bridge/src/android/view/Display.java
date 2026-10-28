package android.view;

import android.util.DisplayMetrics;

/**
 * android.view.Display 的桌面实现：按 1920×1080 的横屏电视报告尺寸（载荷据此决定弹窗宽度）。
 */
public class Display {

    public static final int DEFAULT_DISPLAY = 0;

    public int getWidth() {
        return 1920;
    }

    public int getHeight() {
        return 1080;
    }

    public int getDisplayId() {
        return DEFAULT_DISPLAY;
    }

    public int getRotation() {
        return 0;
    }

    public void getMetrics(DisplayMetrics outMetrics) {
        if (outMetrics == null) return;
        outMetrics.widthPixels = getWidth();
        outMetrics.heightPixels = getHeight();
    }

    public void getRealMetrics(DisplayMetrics outMetrics) {
        getMetrics(outMetrics);
    }
}
