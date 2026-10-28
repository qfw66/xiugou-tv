package android.view.inputmethod;

import android.os.IBinder;
import android.view.View;

/**
 * android.view.inputmethod.InputMethodManager 的桌面实现：没有软键盘，显示 / 隐藏一律视为成功。
 */
public class InputMethodManager {

    public static final int SHOW_IMPLICIT = 1;
    public static final int SHOW_FORCED = 2;
    public static final int HIDE_IMPLICIT_ONLY = 1;
    public static final int HIDE_NOT_ALWAYS = 2;

    public boolean showSoftInput(View view, int flags) {
        return true;
    }

    public boolean hideSoftInputFromWindow(IBinder windowToken, int flags) {
        return true;
    }

    public void toggleSoftInput(int showFlags, int hideFlags) {
    }

    public boolean isActive() {
        return false;
    }
}
