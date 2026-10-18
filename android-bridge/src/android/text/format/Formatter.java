package android.text.format;

/**
 * 极简 Formatter 桩：加固载荷用 formatIpAddress 把 int 转成 IPv4 字符串。
 * 桌面端只需要一个不会抛异常的实现。
 */
public class Formatter {

    public static String formatIpAddress(int ip) {
        return ((ip & 0xff) + "." + ((ip >> 8) & 0xff) + "." + ((ip >> 16) & 0xff) + "." + ((ip >> 24) & 0xff));
    }
}
