package android.webkit;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * android.webkit.CookieManager 的桌面实现。
 *
 * <p>载荷（如王二小 {@code Wexyingchao}）在拉起网页前会把网盘 / 站点 Cookie 写进 CookieManager，
 * 之后也可能用 {@link #getCookie(String)} 读回。Android 上 CookieManager 是持久的，这里同样落盘：
 * 按「主机」存进 SharedPreferences {@code webview_cookies}（即 {@code ~/.xiugou_tv_companion/prefs}），
 * 跨重启保留，「重置所有设置」随 prefs 目录一起清掉。
 *
 * <p>只做按主机的名值存取，不实现路径 / 过期 / Secure 等细则；桌面 WebView 本身不发请求。
 */
public class CookieManager {

    private static final String PREFS = "webview_cookies";
    private static final CookieManager INSTANCE = new CookieManager();

    private volatile boolean acceptCookie = true;

    protected CookieManager() {
    }

    public static CookieManager getInstance() {
        return INSTANCE;
    }

    private static SharedPreferences store() {
        return Context.get().getSharedPreferences(PREFS, 0);
    }

    /** {@code https://pan.quark.cn/list?x=1} → {@code pan.quark.cn}；无协议时按主机名处理。 */
    static String hostOf(String url) {
        if (url == null) return "";
        String s = url.trim();
        int scheme = s.indexOf("://");
        if (scheme >= 0) s = s.substring(scheme + 3);
        int end = s.length();
        for (char c : new char[]{'/', '?', '#'}) {
            int i = s.indexOf(c);
            if (i >= 0 && i < end) end = i;
        }
        s = s.substring(0, end);
        int at = s.lastIndexOf('@');
        if (at >= 0) s = s.substring(at + 1);
        int colon = s.indexOf(':');
        if (colon >= 0) s = s.substring(0, colon);
        return s.toLowerCase(Locale.ROOT);
    }

    private static Map<String, String> parse(String header) {
        Map<String, String> out = new LinkedHashMap<>();
        if (header == null) return out;
        for (String part : header.split(";")) {
            String p = part.trim();
            if (p.isEmpty()) continue;
            int eq = p.indexOf('=');
            String name = (eq < 0 ? p : p.substring(0, eq)).trim();
            if (name.isEmpty()) continue;
            out.put(name, eq < 0 ? "" : p.substring(eq + 1).trim());
        }
        return out;
    }

    private static String join(Map<String, String> cookies) {
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : cookies.entrySet()) {
            if (sb.length() > 0) sb.append("; ");
            sb.append(e.getKey()).append('=').append(e.getValue());
        }
        return sb.toString();
    }

    /** Set-Cookie 的属性名（不是 Cookie 本身）。 */
    private static boolean isAttribute(String name) {
        switch (name.toLowerCase(Locale.ROOT)) {
            case "path": case "domain": case "expires": case "max-age": case "secure":
            case "httponly": case "samesite": case "priority": case "version": case "comment":
                return true;
            default:
                return false;
        }
    }

    public void setAcceptCookie(boolean accept) {
        acceptCookie = accept;
    }

    public boolean acceptCookie() {
        return acceptCookie;
    }

    public void setAcceptThirdPartyCookies(WebView webView, boolean accept) {
    }

    public boolean acceptThirdPartyCookies(WebView webView) {
        return true;
    }

    /**
     * 与 Android 一致：value 可以是单个 {@code name=value}，也可以带 Set-Cookie 属性；
     * 这里只取第一段名值（其余属性忽略），同名覆盖。值为空串表示删除该 Cookie。
     */
    public synchronized void setCookie(String url, String value) {
        if (!acceptCookie) return;
        String host = hostOf(url);
        if (host.isEmpty() || value == null) return;
        String first = value.split(";", 2)[0].trim();
        int eq = first.indexOf('=');
        if (eq <= 0) return;
        String name = first.substring(0, eq).trim();
        if (isAttribute(name)) return;
        Map<String, String> cookies = parse(store().getString(host, null));
        String v = first.substring(eq + 1).trim();
        if (v.isEmpty()) cookies.remove(name);
        else cookies.put(name, v);
        store().edit().putString(host, join(cookies)).apply();
    }

    public void setCookie(String url, String value, ValueCallback<Boolean> callback) {
        setCookie(url, value);
        if (callback != null) callback.onReceiveValue(Boolean.TRUE);
    }

    /** 返回该主机及其各级父域（不含顶级后缀）上的 Cookie，与浏览器的域匹配方向一致。 */
    public synchronized String getCookie(String url) {
        String host = hostOf(url);
        if (host.isEmpty()) return null;
        Map<String, String> merged = new LinkedHashMap<>();
        List<String> chain = new ArrayList<>();
        String h = host;
        while (h.indexOf('.') > 0) {
            chain.add(0, h);
            h = h.substring(h.indexOf('.') + 1);
        }
        if (chain.isEmpty()) chain.add(host);
        for (String domain : chain) merged.putAll(parse(store().getString(domain, null)));
        return merged.isEmpty() ? null : join(merged);
    }

    public boolean hasCookies() {
        return !store().getAll().isEmpty();
    }

    public synchronized void removeAllCookies(ValueCallback<Boolean> callback) {
        boolean had = hasCookies();
        store().edit().clear().apply();
        if (callback != null) callback.onReceiveValue(had);
    }

    public void removeAllCookie() {
        removeAllCookies(null);
    }

    public void removeSessionCookies(ValueCallback<Boolean> callback) {
        if (callback != null) callback.onReceiveValue(Boolean.FALSE);
    }

    public void removeSessionCookie() {
    }

    public void removeExpiredCookie() {
    }

    /** 每次 setCookie 已即时落盘。 */
    public void flush() {
    }
}
