package android.app;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;

/**
 * android.app.Activity 的桌面实现。
 *
 * <p>进程里只有一个常驻前台界面（{@link #foreground()}），对应 FongMi 的首页；
 * 载荷在它上面创建的弹窗由 {@link DialogHost} 交给宿主呈现。
 * UI 调用仍按「立即在调用线程执行」处理，与既有行为一致。
 */
public class Activity extends Context {

    private static final Activity FOREGROUND = new Activity();

    private final Window window = new Window();

    /** 桌面端唯一的前台界面（桌面扩展）。 */
    public static Activity foreground() {
        return FOREGROUND;
    }

    public void runOnUiThread(Runnable action) {
        if (action != null) action.run();
    }

    public boolean isFinishing() {
        return false;
    }

    public boolean isDestroyed() {
        return false;
    }

    public void finish() {
    }

    public void onCreate(android.os.Bundle savedInstanceState) {
    }

    public Intent getIntent() {
        return new Intent();
    }

    public ComponentName getComponentName() {
        return new ComponentName(getPackageName(), "com.fongmi.android.tv.ui.activity.HomeActivity");
    }

    public Window getWindow() {
        return window;
    }

    public WindowManager getWindowManager() {
        return new WindowManager() {
        };
    }

    public View findViewById(int id) {
        return window.findViewById(id);
    }

    public void requestPermissions(String[] permissions, int requestCode) {
    }

    public int checkSelfPermission(String permission) {
        return 0;
    }

    public void setRequestedOrientation(int requestedOrientation) {
    }
}
