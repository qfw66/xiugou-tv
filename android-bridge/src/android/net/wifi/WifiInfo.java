package android.net.wifi;

/**
 * 顶层 {@code android.net.wifi.WifiInfo} 桩。
 *
 * <p>注意：它必须是**顶层类**，不能写成 {@code WifiManager} 的内部类。
 * 加固载荷按描述符 {@code ()Landroid/net/wifi/WifiInfo;} 查找方法返回值，
 * 内部类的描述符是 {@code Landroid/net/wifi/WifiManager$WifiInfo;}，
 * 二者不匹配会抛
 * {@code NoSuchMethodError: android.net.wifi.WifiInfo WifiManager.getConnectionInfo()}，
 * 直接导致整个 {@code Config}/壳初始化链路失败（表现为该站 0 数据）。
 *
 * <p>桌面端没有真实网卡信息，取值全部给安全默认值。
 */
public class WifiInfo {

    public int getIpAddress() {
        return 0;
    }

    public String getMacAddress() {
        return "02:00:00:00:00:00";
    }

    public String getSSID() {
        return "<unknown ssid>";
    }

    public String getBSSID() {
        return "02:00:00:00:00:00";
    }

    public int getNetworkId() {
        return -1;
    }

    public int getRssi() {
        return -127;
    }

    public int getLinkSpeed() {
        return 0;
    }

    public int getFrequency() {
        return 0;
    }

    public boolean getHiddenSSID() {
        return false;
    }

    public int getSupplicantState() {
        return 0;
    }
}
