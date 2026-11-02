package android.net.ssl;

import javax.net.ssl.SSLSocket;

/**
 * Conscrypt 专属的 SSLSocket 调优入口。桌面 JVM 的套接字不是 Conscrypt 实现，
 * 与 Android 上遇到非 Conscrypt 套接字时一致：isSupportedSocket 返回 false，其余调用抛 IllegalArgumentException，
 * 载荷（OkHttp 的 Android10Platform 等）据此跳过调优。
 */
public final class SSLSockets {

    private SSLSockets() {
    }

    public static boolean isSupportedSocket(SSLSocket socket) {
        return false;
    }

    public static void setUseSessionTickets(SSLSocket socket, boolean useSessionTickets) {
        throw new IllegalArgumentException("Socket is not a supported socket.");
    }
}
