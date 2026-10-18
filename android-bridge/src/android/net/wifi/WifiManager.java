package android.net.wifi;

/**
 * 极简 WifiManager 桩：仅为满足加固载荷（config/ProxyOrigin 家族）对
 * 局域网信息的签名解析。
 *
 * <p>{@link #getConnectionInfo()} 的返回类型必须是**顶层** {@link WifiInfo}，
 * 与 Android 的描述符一致；返回 null 会让调用方在 {@code getIpAddress()} 上 NPE，
 * 因此这里给一个不含真实信息的实例。
 */
public class WifiManager {

    public WifiInfo getConnectionInfo() {
        return new WifiInfo();
    }

    public boolean isWifiEnabled() {
        return false;
    }

    public boolean setWifiEnabled(boolean enabled) {
        return false;
    }

    public java.util.List<ScanResult> getScanResults() {
        return new java.util.ArrayList<ScanResult>();
    }

    /** 扫描结果桩，载荷只做类型引用。 */
    public static class ScanResult {
        public String SSID;
        public String BSSID;
        public int level;
    }
}
