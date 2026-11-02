package android.text.format;

/**
 * 极简 Formatter 桩：加固载荷用 formatIpAddress 把 int 转成 IPv4 字符串。
 * 桌面端只需要一个不会抛异常的实现。
 */
public class Formatter {

    public static String formatIpAddress(int ip) {
        return ((ip & 0xff) + "." + ((ip >> 8) & 0xff) + "." + ((ip >> 16) & 0xff) + "." + ((ip >> 24) & 0xff));
    }
    /** 按 Android 的 1000 进制与有效位规则格式化文件大小（如 1.2 MB）。 */
    public static String formatFileSize(android.content.Context context, long sizeBytes) {
        return format(sizeBytes, false);
    }

    public static String formatShortFileSize(android.content.Context context, long sizeBytes) {
        return format(sizeBytes, true);
    }

    private static String format(long sizeBytes, boolean shorter) {
        boolean negative = sizeBytes < 0;
        float result = Math.abs(sizeBytes);
        String[] units = {"B", "kB", "MB", "GB", "TB", "PB"};
        int unit = 0;
        while (result > 900 && unit < units.length - 1) {
            result /= 1000;
            unit++;
        }
        String value;
        if (unit == 0 || result >= 100) {
            value = String.format(java.util.Locale.ROOT, "%.0f", result);
        } else if (result < 1) {
            value = String.format(java.util.Locale.ROOT, "%.2f", result);
        } else if (result < 10) {
            value = String.format(java.util.Locale.ROOT, shorter ? "%.1f" : "%.2f", result);
        } else {
            value = String.format(java.util.Locale.ROOT, shorter ? "%.0f" : "%.2f", result);
        }
        return (negative ? "-" : "") + value + " " + units[unit];
    }
}
