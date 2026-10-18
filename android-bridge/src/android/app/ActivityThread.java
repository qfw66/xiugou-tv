package android.app;

/**
 * Minimal android.app.ActivityThread stub。
 * spider jar 的 Init.getActivity() 会反射调用本类拿 Application/Activity。
 */
public class ActivityThread {

    public static ActivityThread currentActivityThread() {
        return new ActivityThread();
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
}
