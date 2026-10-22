package com.github.catvod.utils;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

import okhttp3.Request;

/**
 * 请求头伪装/覆盖（默认关闭）。
 *
 * <p>用途：怀疑某些站点按 UA/Referer 分流（桌面浏览器给 HTML、App 给 JSON）时，
 * 可以不改代码直接做 A/B。所有取值都来自 JVM 系统属性：
 *
 * <pre>
 *   -Dxiugou.http.preset=android-app   // okhttp/3.12.1 + X-Requested-With + zh-CN
 *   -Dxiugou.http.preset=android-web   // Android Chrome Mobile UA
 *   -Dxiugou.http.preset=tvbox         // 仅 okhttp/3.12.1
 *   -Dxiugou.http.ua=...               // 单独指定 UA
 *   -Dxiugou.http.referer=...          // 单独指定 Referer
 *   -Dxiugou.http.cookie=...           // 单独指定 Cookie
 *   -Dxiugou.http.headers=K1:V1;K2:V2  // 追加/覆盖任意头
 *   -Dxiugou.http.force=true           // 连爬虫自己设置的 UA 也覆盖（默认只补缺失的）
 * </pre>
 *
 * <p>默认 `force=false`：只补爬虫没设置的头，避免把本来正常的站点带坏。
 */
public final class HeaderOverride {

    private static final boolean ENABLED;
    private static final boolean FORCE;
    private static final Map<String, String> HEADERS;

    static {
        Map<String, String> map = new LinkedHashMap<>();
        String preset = prop("xiugou.http.preset", "").toLowerCase(Locale.ROOT);
        switch (preset) {
            case "android-app":
                map.put("User-Agent", "okhttp/3.12.1");
                map.put("X-Requested-With", "com.fongmi.android.tv");
                map.put("Accept-Language", "zh-CN,zh;q=0.9");
                break;
            case "android-web":
                map.put("User-Agent", "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) "
                        + "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36");
                map.put("X-Requested-With", "com.fongmi.android.tv");
                map.put("Accept-Language", "zh-CN,zh;q=0.9");
                break;
            case "tvbox":
                map.put("User-Agent", "okhttp/3.12.1");
                break;
            default:
                break;
        }
        putIfPresent(map, "User-Agent", prop("xiugou.http.ua", ""));
        putIfPresent(map, "Referer", prop("xiugou.http.referer", ""));
        putIfPresent(map, "Cookie", prop("xiugou.http.cookie", ""));
        String extra = prop("xiugou.http.headers", "");
        for (String part : extra.split(";")) {
            int idx = part.indexOf(':');
            if (idx > 0) {
                String name = part.substring(0, idx).trim();
                String value = part.substring(idx + 1).trim();
                if (!name.isEmpty()) map.put(name, value);
            }
        }
        // Accept-Encoding 交给客户端自己协商：手动设置会让 HttpURLConnection 不再自动解压。
        map.remove("Accept-Encoding");
        HEADERS = Collections.unmodifiableMap(map);
        ENABLED = !HEADERS.isEmpty();
        FORCE = bool("xiugou.http.force", false);
    }

    private HeaderOverride() {
    }

    public static boolean enabled() {
        return ENABLED;
    }

    public static boolean force() {
        return FORCE;
    }

    /** 供 HttpURLConnection 桩使用：返回应用覆盖后的新 Map。 */
    public static Map<String, String> apply(Map<String, String> headers) {
        if (!ENABLED) return headers;
        Map<String, String> out = headers == null
                ? new LinkedHashMap<>()
                : new LinkedHashMap<>(headers);
        for (Map.Entry<String, String> entry : HEADERS.entrySet()) {
            if (FORCE || !containsIgnoreCase(out, entry.getKey())) {
                putIgnoreCase(out, entry.getKey(), entry.getValue());
            }
        }
        return out;
    }

    /** 供 OkHttp 拦截器使用：按需改写 Request。 */
    public static Request apply(Request request) {
        if (!ENABLED || request == null) return request;
        Request.Builder builder = request.newBuilder();
        boolean changed = false;
        for (Map.Entry<String, String> entry : HEADERS.entrySet()) {
            if (FORCE || request.header(entry.getKey()) == null) {
                builder.header(entry.getKey(), entry.getValue());
                changed = true;
            }
        }
        return changed ? builder.build() : request;
    }

    private static boolean containsIgnoreCase(Map<String, String> map, String name) {
        for (String key : map.keySet()) {
            if (key.equalsIgnoreCase(name)) return true;
        }
        return false;
    }

    private static void putIgnoreCase(Map<String, String> map, String name, String value) {
        String existing = null;
        for (String key : map.keySet()) {
            if (key.equalsIgnoreCase(name)) {
                existing = key;
                break;
            }
        }
        if (existing != null) map.remove(existing);
        map.put(name, value);
    }

    private static void putIfPresent(Map<String, String> map, String name, String value) {
        if (value != null && !value.trim().isEmpty()) map.put(name, value.trim());
    }

    private static String prop(String key, String fallback) {
        String value = System.getProperty(key);
        return value == null ? fallback : value;
    }

    private static boolean bool(String key, boolean fallback) {
        String value = System.getProperty(key);
        if (value == null || value.trim().isEmpty()) return fallback;
        return "true".equalsIgnoreCase(value.trim()) || "1".equals(value.trim());
    }
}
