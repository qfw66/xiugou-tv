package android.content;

import java.util.concurrent.ConcurrentHashMap;

/**
 * Minimal Android Context stub for standard JVM environment.
 */
public class Context {
    private static final Context INSTANCE = new Context();

    /** 按名字全局共享（Application/Context/Activity 各实例看到同一份） */
    private static final ConcurrentHashMap<String, SharedPreferences> PREFS = new ConcurrentHashMap<>();

    public static Context get() {
        return INSTANCE;
    }

    public Object getSystemService(String name) {
        return null;
    }

    public Context getApplicationContext() {
        return INSTANCE;
    }

    public SharedPreferences getSharedPreferences(String name, int mode) {
        final String key = (name == null || name.trim().isEmpty()) ? "default" : name;
        return PREFS.computeIfAbsent(key, k -> new SharedPreferencesImpl(k, prefsDir()));
    }

    /** 载荷初始化路径会取 ContentResolver（读取系统设置/监听变化），返回共享 stub 实例。 */
    public ContentResolver getContentResolver() {
        return CONTENT_RESOLVER;
    }

    private static final ContentResolver CONTENT_RESOLVER = new ContentResolver();

    /** 载荷（merge.ME.q 等）取 DisplayMetrics 做 dp→px 换算。 */
    public android.content.res.Resources getResources() {
        return RESOURCES;
    }

    private static final android.content.res.Resources RESOURCES = new android.content.res.Resources();

    /** 壳的 native 加载器 / 签名模块会读这个对象来定位 so 与资源。 */
    public android.content.pm.ApplicationInfo getApplicationInfo() {
        return APPLICATION_INFO;
    }

    private static final android.content.pm.ApplicationInfo APPLICATION_INFO =
            new android.content.pm.ApplicationInfo();

    private static java.io.File prefsDir() {
        java.io.File dir = new java.io.File(
                new java.io.File(System.getProperty("user.home", "."), ".xiugou_tv_companion"), "prefs");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public String getPackageName() {
        return "com.fongmi.android.tv";
    }

    public java.io.File getCacheDir() {
        java.io.File dir = new java.io.File(System.getProperty("java.io.tmpdir"), "xiugou_tv_cache");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public java.io.File getFilesDir() {
        java.io.File dir = new java.io.File(System.getProperty("java.io.tmpdir"), "xiugou_tv_files");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }
}
