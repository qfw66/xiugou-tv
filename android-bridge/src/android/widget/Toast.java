package android.widget;

import android.app.DialogHost;
import android.content.Context;

/**
 * android.widget.Toast：交给宿主显示为应用内提示（载荷用它反馈「cookie 已设置」等结果）。
 */
public class Toast {

    public static final int LENGTH_SHORT = 0;
    public static final int LENGTH_LONG = 1;

    private CharSequence text;

    private Toast(CharSequence text) {
        this.text = text;
    }

    public Toast(Context context) {
        this((CharSequence) null);
    }

    public static Toast makeText(Context context, CharSequence text, int duration) {
        System.out.println("[Toast] " + text);
        return new Toast(text);
    }

    public static Toast makeText(Context context, int resId, int duration) {
        return new Toast(context == null ? "" : context.getResources().getString(resId));
    }

    public void setText(CharSequence s) {
        this.text = s;
    }

    public void show() {
        if (text == null || text.length() == 0) return;
        System.out.println("[Toast.show] " + text);
        DialogHost.get().onToast(text);
    }

    public void cancel() {
    }

    public void setDuration(int duration) {
    }

    public void setGravity(int gravity, int xOffset, int yOffset) {
    }

    public void setView(android.view.View view) {
    }
}
