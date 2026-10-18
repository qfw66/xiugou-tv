package android.provider;

import android.content.ContentResolver;

/**
 * Minimal android.provider.Settings stub for standard JVM environment.
 * 加固载荷初始化路径会读取 Settings.Secure 内容（如 android_id / 系统标识）。
 */
public class Settings {

    public static final class Secure {

        public static String getString(ContentResolver resolver, String name) {
            return null;
        }

        public static int getInt(ContentResolver resolver, String name, int def) {
            return def;
        }

        public static boolean putString(ContentResolver resolver, String name, String value) {
            return false;
        }
    }

    public static final class Global {

        public static String getString(ContentResolver resolver, String name) {
            return null;
        }

        public static int getInt(ContentResolver resolver, String name, int def) {
            return def;
        }
    }

    public static final class System {

        public static String getString(ContentResolver resolver, String name) {
            return null;
        }

        public static int getInt(ContentResolver resolver, String name, int def) {
            return def;
        }
    }
}
