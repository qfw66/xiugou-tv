package android.provider;

import android.content.ContentResolver;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * Minimal android.provider.Settings stub for standard JVM environment.
 *
 * <p>加固载荷初始化路径会读 {@code Settings.Secure.getString(cr, "android_id")} 拿设备标识，
 * 再用它参与签名/加密。桌面端如果这里返回 {@code null}，一个 null 字符串会一路传下去，
 * 最终在 {@code String.getBytes(...)} 处炸掉——而且是一条通病：aowu 载荷里二十来个
 * 站点共用同一个「云盘模块」静态初始化，一处 null 连坐一片。
 *
 * <p>所以这里返回一个**稳定**的伪设备标识：同一台机器每次运行一致（站点会把设备号
 * 缓存进配置，每次都变会让缓存失效），但不是真机值。
 */
public class Settings {

    /** 伪 android_id：16 位十六进制，与真机格式一致。 */
    private static final String ANDROID_ID = syntheticId();

    private static String syntheticId() {
        try {
            String seed = java.lang.System.getProperty("user.name", "")
                    + '|' + java.lang.System.getProperty("os.name", "")
                    + '|' + java.lang.System.getProperty("os.version", "")
                    + "|xiugou-tv-companion";
            byte[] d = MessageDigest.getInstance("MD5")
                    .digest(seed.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(16);
            for (int i = 0; i < 8; i++) {
                sb.append(String.format("%02x", d[i]));
            }
            return sb.toString();
        } catch (Exception e) {
            return "0123456789abcdef";
        }
    }

    public static final class Secure {

        public static String getString(ContentResolver resolver, String name) {
            if (name == null) return null;
            switch (name) {
                case "android_id":
                    return ANDROID_ID;
                case "bluetooth_name":
                case "device_name":
                    return "xiugou-desktop";
                case "default_input_method":
                    return "com.android.inputmethod.latin/.LatinIME";
                default:
                    return null;
            }
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
            if (name == null) return null;
            switch (name) {
                case "device_name":
                    return "xiugou-desktop";
                case "advertising_id":
                case "oaid":
                    // 平台还没给广告标识时，载荷会退回 android_id；这里给一个稳定值免得为 null
                    return ANDROID_ID;
                default:
                    return null;
            }
        }

        public static int getInt(ContentResolver resolver, String name, int def) {
            return def;
        }

        public static boolean putString(ContentResolver resolver, String name, String value) {
            return false;
        }
    }

    public static final class System {

        public static String getString(ContentResolver resolver, String name) {
            if (name == null) return null;
            switch (name) {
                case "screen_brightness":
                    return "128";
                case "android_id":
                    return ANDROID_ID;
                default:
                    return null;
            }
        }

        public static int getInt(ContentResolver resolver, String name, int def) {
            return def;
        }

        public static boolean putString(ContentResolver resolver, String name, String value) {
            return false;
        }
    }

    /** 供同一台机器上其它 shim（如 Build 字段）复用同一个伪标识。 */
    public static String deviceId() {
        return ANDROID_ID;
    }
}
