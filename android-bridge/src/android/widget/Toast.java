package android.widget;

import android.content.Context;

/**
 * Minimal android.widget.Toast stub（无 UI，仅日志）。
 */
public class Toast {

    public static final int LENGTH_SHORT = 0;
    public static final int LENGTH_LONG = 1;

    private final CharSequence text;

    private Toast(CharSequence text) {
        this.text = text;
    }

    public static Toast makeText(Context context, CharSequence text, int duration) {
        System.out.println("[Toast] " + text);
        return new Toast(text);
    }

    public static Toast makeText(Context context, int resId, int duration) {
        return new Toast("res:" + resId);
    }

    public void show() {
        if (text != null) System.out.println("[Toast.show] " + text);
    }

    public void cancel() {
    }

    public void setDuration(int duration) {
    }
}
