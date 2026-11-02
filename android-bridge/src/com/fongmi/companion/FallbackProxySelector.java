package com.fongmi.companion;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.URI;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * 「先直连、直连失败再走系统代理」的默认 ProxySelector（§59，验收单 E7）。
 *
 * 背景：部分站源接口在国内直连被重置（实测文才┃秒播 的 www.hkybqufgh.com：直连 TLS 握手即断，
 * 经用户的 Clash 代理 200），而 companion（Java）默认完全不走系统代理，站源首页因此为空。
 * 反过来，让 companion 整体走系统代理（-Djava.net.useSystemProxies=true）又会让 uc / 迅雷 / 百度 /
 * 嗷呜等国内服务全部 SSL 失败（2026-11-01 实测），所以不能「全走代理」。
 *
 * 做法：对外网 http(s) 返回 [DIRECT, 代理] 两条路由。OkHttp（载荷的网络栈）与 HttpURLConnection
 * 都会按顺序尝试，前一条建连失败（连接被拒 / 重置 / 超时 / 握手中断）才用下一条，
 * 所以直连能通的请求行为完全不变。回环、局域网地址只给 DIRECT（本机代理端口、局域网服务不绕路）。
 *
 * 只有启动参数 {@code --fallback-proxy=host:port} 给了代理时才安装；宿主（Flutter）只在
 * Windows 系统代理开启时传这个参数，否则 companion 行为与以前一致。
 */
public final class FallbackProxySelector extends ProxySelector {

    private final Proxy proxy;
    private final List<Proxy> directThenProxy;

    FallbackProxySelector(Proxy proxy) {
        this.proxy = proxy;
        this.directThenProxy = Collections.unmodifiableList(Arrays.asList(Proxy.NO_PROXY, proxy));
    }

    /**
     * 解析 {@code host:port}（可带 {@code http://} 前缀），合法时安装为 JVM 默认 ProxySelector。
     * 必须在任何 OkHttpClient.Builder 创建之前调用：Builder 在构造时就读取默认值。
     *
     * @return 是否已安装
     */
    public static boolean install(String spec) {
        Proxy proxy = parse(spec);
        if (proxy == null) return false;
        ProxySelector.setDefault(new FallbackProxySelector(proxy));
        System.out.println("[NetFallback] 直连失败时改走系统代理 " + proxy.address());
        return true;
    }

    static Proxy parse(String spec) {
        if (spec == null) return null;
        String value = spec.trim().replaceFirst("(?i)^[a-z]+://", "");
        if (value.endsWith("/")) value = value.substring(0, value.length() - 1);
        int colon = value.lastIndexOf(':');
        if (colon <= 0 || colon == value.length() - 1) return null;
        String host = value.substring(0, colon);
        int port;
        try {
            port = Integer.parseInt(value.substring(colon + 1));
        } catch (NumberFormatException e) {
            return null;
        }
        if (port <= 0 || port > 65535 || host.isEmpty()) return null;
        return new Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(host, port));
    }

    @Override
    public List<Proxy> select(URI uri) {
        if (uri == null) throw new IllegalArgumentException("uri == null");
        String scheme = uri.getScheme();
        String host = uri.getHost();
        if (scheme == null || host == null) return Collections.singletonList(Proxy.NO_PROXY);
        String s = scheme.toLowerCase();
        if (!s.equals("http") && !s.equals("https")) return Collections.singletonList(Proxy.NO_PROXY);
        if (isLocal(host)) return Collections.singletonList(Proxy.NO_PROXY);
        return directThenProxy;
    }

    /** 回环 / 局域网 / 链路本地地址与无点主机名不走代理（与 Windows 代理的「本地地址不使用代理」一致）。 */
    static boolean isLocal(String host) {
        String h = host.toLowerCase();
        if (h.startsWith("[") && h.endsWith("]")) h = h.substring(1, h.length() - 1);
        if (h.equals("localhost") || h.endsWith(".localhost") || h.equals("::1")) return true;
        if (h.indexOf('.') < 0 && h.indexOf(':') < 0) return true;
        if (!h.matches("[0-9.]+")) return false; // 域名：交给路由顺序处理，不在这里解析 DNS
        try {
            InetAddress addr = InetAddress.getByName(h); // 纯数字 IP 不触发 DNS
            return addr.isLoopbackAddress() || addr.isSiteLocalAddress()
                    || addr.isLinkLocalAddress() || addr.isAnyLocalAddress();
        } catch (IOException e) {
            return false;
        }
    }

    @Override
    public void connectFailed(URI uri, SocketAddress sa, IOException ioe) {
        // 代理本身也连不上：不做额外处理，调用方会按普通网络错误收尾。
        if (sa != null && proxy.address().toString().equals(sa.toString())) {
            com.github.catvod.utils.DebugLog.line("NetFallback", "系统代理也不可用: " + uri.getHost() + " " + ioe);
        }
    }
}
