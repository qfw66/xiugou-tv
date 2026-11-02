package android.view;

import android.content.Context;

/**
 * 交互相关的标准尺寸与时长（AOSP 默认值，按 160dpi 即 1dp = 1px 换算）。
 */
public class ViewConfiguration {

    private static final ViewConfiguration INSTANCE = new ViewConfiguration();

    public static ViewConfiguration get(Context context) {
        return INSTANCE;
    }

    public int getScaledTouchSlop() {
        return 8;
    }

    public int getScaledDoubleTapSlop() {
        return 100;
    }

    public int getScaledPagingTouchSlop() {
        return 16;
    }

    public int getScaledMinimumFlingVelocity() {
        return 50;
    }

    public int getScaledMaximumFlingVelocity() {
        return 8000;
    }

    public int getScaledScrollBarSize() {
        return 4;
    }

    public int getScaledOverscrollDistance() {
        return 0;
    }

    public int getScaledOverflingDistance() {
        return 6;
    }

    public boolean hasPermanentMenuKey() {
        return false;
    }

    public static int getTapTimeout() {
        return 100;
    }

    public static int getDoubleTapTimeout() {
        return 300;
    }

    public static int getLongPressTimeout() {
        return 400;
    }

    public static int getPressedStateDuration() {
        return 64;
    }

    public static int getKeyRepeatTimeout() {
        return getLongPressTimeout();
    }

    public static int getKeyRepeatDelay() {
        return 50;
    }
}
