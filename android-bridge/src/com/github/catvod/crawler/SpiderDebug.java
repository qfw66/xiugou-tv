package com.github.catvod.crawler;

import android.text.TextUtils;

/**
 * 与手机端 TVBox `catvod` 模块同名宿主类（上游包 `com.github.catvod.crawler`）。
 * 手机端用 Logger 输出；桌面端输出到 stdout 便于伴随服务日志排查。
 */
public class SpiderDebug {

    private static final String TAG = SpiderDebug.class.getSimpleName();

    public static void log(Throwable th) {
        if (th != null) th.printStackTrace();
    }

    public static void log(String msg) {
        if (!TextUtils.isEmpty(msg)) System.out.println("[" + TAG + "] " + msg);
    }

    public static void log(String tag, String msg, Object... args) {
        if (TextUtils.isEmpty(msg)) return;
        String line = (args == null || args.length == 0) ? msg : String.format(msg, args);
        System.out.println("[" + tag + "] " + line);
    }
}
