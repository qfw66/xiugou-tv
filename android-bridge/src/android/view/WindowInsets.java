package android.view;

import android.graphics.Insets;

/**
 * 窗口内距。桌面窗口没有状态栏、导航栏、刘海与输入法占位，各类内距均为 0。
 */
public final class WindowInsets {

    /** 全零内距（桌面扩展常量，Android 上同名常量表示「已消费」，含义同样是全零）。 */
    public static final WindowInsets CONSUMED = new WindowInsets();

    private WindowInsets() {
    }

    public Insets getInsets(int typeMask) {
        return Insets.NONE;
    }

    public Insets getInsetsIgnoringVisibility(int typeMask) {
        return Insets.NONE;
    }

    public boolean isVisible(int typeMask) {
        return false;
    }

    public int getSystemWindowInsetLeft() {
        return 0;
    }

    public int getSystemWindowInsetTop() {
        return 0;
    }

    public int getSystemWindowInsetRight() {
        return 0;
    }

    public int getSystemWindowInsetBottom() {
        return 0;
    }

    public boolean hasSystemWindowInsets() {
        return false;
    }

    public boolean isConsumed() {
        return true;
    }

    public WindowInsets consumeSystemWindowInsets() {
        return this;
    }

    /** 内距类型位掩码，取值与 AOSP 一致。 */
    public static final class Type {

        private Type() {
        }

        public static int statusBars() {
            return 1;
        }

        public static int navigationBars() {
            return 1 << 1;
        }

        public static int captionBar() {
            return 1 << 2;
        }

        public static int ime() {
            return 1 << 3;
        }

        public static int systemGestures() {
            return 1 << 4;
        }

        public static int mandatorySystemGestures() {
            return 1 << 5;
        }

        public static int tappableElement() {
            return 1 << 6;
        }

        public static int displayCutout() {
            return 1 << 7;
        }

        public static int systemBars() {
            return statusBars() | navigationBars() | captionBar();
        }
    }
}
