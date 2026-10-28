package android.app;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * android.app.ActivityThread 的桌面实现。
 *
 * <p>载荷（如 wexguard 的 {@code InitOrigin.getActivity()}）用反射读
 * {@code currentActivityThread().mActivities}，遍历记录对象的 {@code paused} / {@code activity}
 * 字段取当前前台界面，再在它上面弹设置窗口。字段名与类型必须与 AOSP 一致，否则反射直接失败。
 */
public final class ActivityThread {

    private static final ActivityThread CURRENT = new ActivityThread();

    /** AOSP 同名字段：token → 界面记录。桌面端只有一个常驻前台界面。 */
    final Map<Object, ActivityClientRecord> mActivities = new LinkedHashMap<>();

    private ActivityThread() {
        mActivities.put(new Object(), new ActivityClientRecord(Activity.foreground()));
    }

    public static ActivityThread currentActivityThread() {
        return CURRENT;
    }

    public static Application currentApplication() {
        return Application.get();
    }

    public static String currentPackageName() {
        return "com.fongmi.android.tv";
    }

    public static void main(String[] args) {
    }

    public Application getApplication() {
        return Application.get();
    }

    /** AOSP 的 {@code ActivityThread$ActivityClientRecord}：字段名是载荷反射的契约。 */
    static final class ActivityClientRecord {
        Activity activity;
        boolean paused;

        ActivityClientRecord(Activity activity) {
            this.activity = activity;
        }
    }
}
