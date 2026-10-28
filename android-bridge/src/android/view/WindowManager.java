package android.view;

/**
 * Minimal android.view.WindowManager stub（含 LayoutParams）。
 */
public interface WindowManager {

    /** 载荷用它取屏宽决定弹窗尺寸。 */
    default Display getDefaultDisplay() {
        return new Display();
    }

    default void addView(android.view.View view, ViewGroup.LayoutParams params) {
    }

    default void removeView(android.view.View view) {
    }

    default void updateViewLayout(android.view.View view, ViewGroup.LayoutParams params) {
    }

    class LayoutParams extends ViewGroup.LayoutParams {

        public static final int TYPE_APPLICATION = 2;
        public static final int TYPE_APPLICATION_OVERLAY = 2038;
        public static final int TYPE_PHONE = 2002;
        public static final int TYPE_SYSTEM_ALERT = 2003;
        public static final int TYPE_TOAST = 2005;

        public static final int FLAG_NOT_FOCUSABLE = 0x00000008;
        public static final int FLAG_NOT_TOUCHABLE = 0x00000010;
        public static final int FLAG_LAYOUT_IN_SCREEN = 0x00000100;
        public static final int FLAG_FULLSCREEN = 0x00000400;
        public static final int FLAG_LAYOUT_NO_LIMITS = 0x00000200;

        public int x;
        public int y;
        public int gravity;
        public int type;
        public int format = -1;
        public int flags;
        public float alpha = 1.0f;
        public float dimAmount = 1.0f;
        public android.os.IBinder token;

        public LayoutParams() {
            super(WRAP_CONTENT, WRAP_CONTENT);
        }

        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(int width, int height, int type) {
            super(width, height);
            this.type = type;
        }

        public LayoutParams(int width, int height, int type, int flags, int format) {
            super(width, height);
            this.type = type;
            this.flags = flags;
            this.format = format;
        }
    }
}
