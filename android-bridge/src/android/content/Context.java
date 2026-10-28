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
        if (name == null) return null;
        switch (name) {
            case "clipboard":
                return CLIPBOARD;
            case "input_method":
                return INPUT_METHOD;
            case "window":
                return WINDOW_MANAGER;
            default:
                return null;
        }
    }

    private static final ClipboardManager CLIPBOARD = new ClipboardManager();
    private static final android.view.inputmethod.InputMethodManager INPUT_METHOD =
            new android.view.inputmethod.InputMethodManager();
    private static final android.view.WindowManager WINDOW_MANAGER = new android.view.WindowManager() {
    };

    /**
     * 桌面端没有 Activity 栈：只处理带数据地址的跳转（打开网页 / 唤起 App），交给宿主呈现，其余忽略。
     */
    public void startActivity(Intent intent) {
        if (intent == null || intent.getData() == null) {
            System.out.println("[Context] ignore startActivity without data: "
                    + (intent == null ? null : intent.getAction()));
            return;
        }
        android.app.DialogHost.get().onOpenUri(intent.getData().toString(), intent.getType());
    }

    public int checkCallingOrSelfPermission(String permission) {
        return 0;
    }

    public ClassLoader getClassLoader() {
        return Context.class.getClassLoader();
    }

    public String getString(int resId) {
        return getResources().getString(resId);
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

    /**
     * 载荷里 7 处调 {@code getPackageManager()}（取版本号/签名/已装列表做设备指纹）。
     *
     * <p>桌面端没有安装 APK，因此返回的 PackageManager 采用**「包未安装」语义**：
     * {@code getPackageInfo} 照常抛 {@link android.content.pm.PackageManager.NameNotFoundException}。
     * 这样载荷走的是它自己写好的 catch 分支（而不是 {@code NoClassDefFoundError} 打断整个
     * {@code InitOrigin.init}），签名校验类站点仍按「拿不到签名」的原有逻辑降级。
     */
    public android.content.pm.PackageManager getPackageManager() {
        return PACKAGE_MANAGER;
    }

    private static final android.content.pm.PackageManager PACKAGE_MANAGER =
            new android.content.pm.PackageManager();

    public java.io.File getCacheDir() {
        return persistentDir("cache", "xiugou_tv_cache");
    }

    public java.io.File getFilesDir() {
        return persistentDir("files", "xiugou_tv_files");
    }

    /**
     * files / cache 放在 {@code user.home/.xiugou_tv_companion} 下：载荷把网盘 cookie、配置中心设置存在这里，
     * 放系统临时目录会被清理，用户就得反复扫码登录。旧版本用的临时目录在首次访问时整体复制过来（不删除原目录）。
     */
    private static java.io.File persistentDir(String name, String legacyTempName) {
        java.io.File dir = new java.io.File(
                new java.io.File(System.getProperty("user.home", "."), ".xiugou_tv_companion"), name);
        if (!dir.exists()) {
            java.io.File legacy = new java.io.File(System.getProperty("java.io.tmpdir"), legacyTempName);
            if (legacy.isDirectory()) copyTree(legacy.toPath(), dir.toPath());
            dir.mkdirs();
        }
        return dir;
    }

    private static void copyTree(java.nio.file.Path from, java.nio.file.Path to) {
        try (java.util.stream.Stream<java.nio.file.Path> walk = java.nio.file.Files.walk(from)) {
            walk.forEach(src -> {
                java.nio.file.Path dst = to.resolve(from.relativize(src).toString());
                try {
                    if (java.nio.file.Files.isDirectory(src)) {
                        java.nio.file.Files.createDirectories(dst);
                    } else {
                        java.nio.file.Files.copy(src, dst, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                    }
                } catch (java.io.IOException ignored) {
                    // 单个文件复制失败（被占用等）不影响其余文件
                }
            });
        } catch (java.io.IOException ignored) {
        }
    }

    /**
     * 载荷的 {@code g8} 会用它拼 SQLite 路径：
     * {@code SQLiteDatabase.openDatabase(context.getDatabasePath(name).getAbsolutePath(), ...)}。
     * 桌面端把数据库文件放在 files/databases 下（目录按需创建）。
     */
    public java.io.File getDatabasePath(String name) {
        java.io.File dir = new java.io.File(getFilesDir(), "databases");
        if (!dir.exists()) dir.mkdirs();
        return new java.io.File(dir, name == null ? "default.db" : name);
    }
}
