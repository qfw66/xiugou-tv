package android.content;

import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;

/**
 * 配置中心（csp_Config）点「设置夸克Cookie / 手动输入」时，载荷在静态初始化里直接执行
 * {@code ((WifiManager) context.getSystemService("wifi")).getConnectionInfo().getIpAddress()}，不判空。
 * 返回 null 会 NPE → ExceptionInInitializerError，那个类此后一直不可用，弹窗再也打不开。
 * 运行：java -ea -cp &lt;classes&gt; android.content.SystemServiceWifiTest
 */
public final class SystemServiceWifiTest {

    public static void main(String[] args) {
        payloadPatternDoesNotThrow();
        sameInstanceEveryTime();
        System.out.println("SystemServiceWifiTest OK");
    }

    private static void payloadPatternDoesNotThrow() {
        Object service = Context.get().getSystemService("wifi");
        assert service instanceof WifiManager : "wifi service must be a WifiManager, got " + service;
        WifiInfo info = ((WifiManager) service).getConnectionInfo();
        assert info != null : "connection info must not be null";
        assert info.getIpAddress() == 0 : "desktop has no Wi-Fi address; payload falls back to its own default";
    }

    private static void sameInstanceEveryTime() {
        assert Context.get().getSystemService("wifi") == Context.get().getSystemService("wifi");
        assert Context.get().getSystemService("connectivity") == null : "connectivity stays null (payload has its own branch)";
    }
}
