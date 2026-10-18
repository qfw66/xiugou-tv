package com.fongmi.android.tv;

import android.app.Activity;
import android.app.Application;

/**
 * 桌面端 stub：手机宿主 Application 类 com.fongmi.android.tv.App。
 *
 * 加固载荷（ftyguard 系列，如 Seedhub/T4/AppTT/AppSx/App99/AiDj 等站点的公共初始化器
 * merge.YU.init）会通过 Class.forName 反射探测本类（类名字符串经混淆解密），
 * 缺失时 InitOrigin.i 保持 null，导致这些站点初始化或首页失败。
 * 这里按手机端 fongmi/TV 的 App 类镜像出载荷可能用到的静态成员。
 */
public class App extends Application {

    private static volatile App instance;

    public App() {
        instance = this;
    }

    public static App get() {
        if (instance == null) {
            instance = new App();
        }
        return instance;
    }

    public static long time() {
        return System.currentTimeMillis();
    }

    public static Activity activity() {
        return null;
    }

    public static void post(Runnable runnable) {
        android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        h.post(runnable);
    }

    public static void post(Runnable runnable, long delayMillis) {
        android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        h.removeCallbacks(runnable);
        if (delayMillis >= 0) {
            h.postDelayed(runnable, delayMillis);
        }
    }

    public static void removeCallbacks(Runnable runnable) {
        android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        h.removeCallbacks(runnable);
    }

    public static void removeCallbacks(Runnable... runnables) {
        android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        for (Runnable r : runnables) {
            h.removeCallbacks(r);
        }
    }
}
