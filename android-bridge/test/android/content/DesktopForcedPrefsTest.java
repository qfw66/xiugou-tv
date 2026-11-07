package android.content;

import java.io.File;
import java.nio.file.Files;

/**
 * 桌面端固定项：网盘载荷的多线程代理模式必须是 java（Go 版依赖 Android 原生库，Windows 起不来）。
 * 运行：java -ea -cp &lt;classes&gt; android.content.DesktopForcedPrefsTest
 */
public final class DesktopForcedPrefsTest {

    public static void main(String[] args) throws Exception {
        File dir = Files.createTempDirectory("xg-forced-prefs").toFile();
        try {
            threadProxyModeIsAlwaysJava(dir);
            otherKeysUnaffected(dir);
        } finally {
            deleteTree(dir);
        }
        System.out.println("DesktopForcedPrefsTest OK");
    }

    private static void threadProxyModeIsAlwaysJava(File dir) {
        SharedPreferencesImpl prefs = new SharedPreferencesImpl("NewWexFnw_preferences", dir);
        assert "java".equals(prefs.getString("pan.thread_proxy_mode", "go")) : "unset key must read java";

        prefs.edit().putString("pan.thread_proxy_mode", "go").commit();
        assert "java".equals(prefs.getString("pan.thread_proxy_mode", "go")) : "stored go must still read java";

        SharedPreferencesImpl restarted = new SharedPreferencesImpl("NewWexFnw_preferences", dir);
        assert "java".equals(restarted.getString("pan.thread_proxy_mode", "go")) : "after reload must read java";
    }

    private static void otherKeysUnaffected(File dir) {
        SharedPreferencesImpl prefs = new SharedPreferencesImpl("other", dir);
        assert "def".equals(prefs.getString("pan.other", "def"));
        prefs.edit().putString("pan.other", "v").commit();
        assert "v".equals(prefs.getString("pan.other", "def"));
        assert "def".equals(prefs.getString(null, "def"));
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) deleteTree(child);
        }
        file.delete();
    }
}
