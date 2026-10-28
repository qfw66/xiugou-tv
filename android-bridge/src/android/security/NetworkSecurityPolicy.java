package android.security;

/**
 * android.security.NetworkSecurityPolicy：桌面端不限制明文 HTTP（与载荷宿主 FongMi 的
 * {@code usesCleartextTraffic=true} 一致；很多站源接口只有 http）。
 */
public class NetworkSecurityPolicy {

    private static final NetworkSecurityPolicy INSTANCE = new NetworkSecurityPolicy();

    public static NetworkSecurityPolicy getInstance() {
        return INSTANCE;
    }

    public boolean isCleartextTrafficPermitted() {
        return true;
    }

    public boolean isCleartextTrafficPermitted(String hostname) {
        return true;
    }
}
