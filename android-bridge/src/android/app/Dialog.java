package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.view.Window;

/**
 * Minimal android.app.Dialog stub。
 */
public class Dialog implements DialogInterface {

    public static final int BUTTON_POSITIVE = -1;
    public static final int BUTTON_NEGATIVE = -2;
    public static final int BUTTON_NEUTRAL = -3;

    private final Context context;
    private boolean showing;

    public Dialog(Context context) {
        this.context = context;
    }

    public Dialog(Context context, int themeResId) {
        this.context = context;
    }

    protected Dialog(Context context, boolean cancelable, OnCancelListener listener) {
        this.context = context;
    }

    public void show() {
        this.showing = true;
    }

    @Override
    public void dismiss() {
        this.showing = false;
    }

    @Override
    public void cancel() {
        this.showing = false;
    }

    public boolean isShowing() {
        return showing;
    }

    public void setTitle(CharSequence title) {
    }

    public void setTitle(int titleId) {
    }

    public void setContentView(View view) {
    }

    public void setContentView(int layoutResID) {
    }

    public void setOnDismissListener(OnDismissListener listener) {
    }

    public void setOnCancelListener(OnCancelListener listener) {
    }

    public void setOnShowListener(OnShowListener listener) {
    }

    public void setCancelable(boolean flag) {
    }

    public void setCanceledOnTouchOutside(boolean cancel) {
    }

    public Window getWindow() {
        return new Window();
    }

    public Context getContext() {
        return context != null ? context : Context.get();
    }
}
