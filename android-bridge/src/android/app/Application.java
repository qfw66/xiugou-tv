package android.app;

import android.content.ContextWrapper;

/**
 * Android Application 的桌面垫片，保留 ContextWrapper 类型契约。
 * 维护进程级单例，供 Init.context() 之类的宿主桥取值。
 */
public class Application extends ContextWrapper {

    private static final Application INSTANCE = new Application();

    public static Application get() {
        return INSTANCE;
    }

    @Override
    public android.content.Context getApplicationContext() {
        return INSTANCE;
    }

    public void onCreate() {
    }

    public void onTerminate() {
    }

    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
    }

    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
    }

    public interface ActivityLifecycleCallbacks {
        default void onActivityCreated(Activity activity, android.os.Bundle savedInstanceState) {
        }

        default void onActivityStarted(Activity activity) {
        }

        default void onActivityResumed(Activity activity) {
        }

        default void onActivityPaused(Activity activity) {
        }

        default void onActivityStopped(Activity activity) {
        }

        default void onActivitySaveInstanceState(Activity activity, android.os.Bundle outState) {
        }

        default void onActivityDestroyed(Activity activity) {
        }
    }
}
