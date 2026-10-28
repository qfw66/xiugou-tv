package com.fongmi.companion;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 拆掉网盘载荷的「本地多线程加速代理」壳，还原成网盘直链。
 *
 * 背景：网盘类载荷（Quark / Ucpan / Wexbaidupan / WexXunLeiPan 等）在 playerContent 里把直链包成
 * {@code http://127.0.0.1:8096/kaiser?url=<urlencoded>&thread=..&chunk=..} 或
 * {@code http://127.0.0.1:8096/proxy?url=<urlencoded>&thread=..&size=..}。
 * 8096 端口由 {@code GoProxy.startServer} 启动，实现在 ARM 版 {@code libwexproxy.so} 里，
 * Windows 上无法加载，于是播放器连 8096 直接被拒（WinError 10061）。
 *
 * 直链本身可用：载荷同时返回的 header（Cookie / UA / Referer）足以让网盘 CDN 回 206
 * （2026-10-27 实测夸克原画：带 header 206 video/x-matroska，不带 header 412）。
 * 因此这里只换 url，header 原样保留，交给播放器单线程直连。
 *
 * 只处理 127.0.0.1:8096 且带 http(s) url 参数的地址；companion 自己的 9978 /proxy 改写
 * （{@link GuardProxyServer#rewriteLocalProxyUrls}）不受影响。
 */
public final class NetdiskProxyUnwrap {

    /** 多线程代理固定监听的端口（载荷里硬编码）。 */
    static final int ACCEL_PORT = 8096;

    private NetdiskProxyUnwrap() {
    }

    /**
     * 改写 playerContent 结果里的 url 字段（字符串，或多清晰度数组 [名称, 地址, ...]）。
     * 拆出的直链交给 {@link NetdiskChunkProxy} 登记成本机分块并发代理地址；代理未就绪时用直链。
     * 不是 JSON、没有命中加速代理时原样返回，不改动其它字段。
     */
    public static String unwrap(String result) {
        if (result == null || !result.contains(":" + ACCEL_PORT)) return result;
        try {
            JSONObject json = new JSONObject(result);
            Map<String, String> headers = headersOf(json.opt("header"));
            Object url = json.opt("url");
            boolean changed = false;
            boolean proxied = false;
            if (url instanceof String) {
                String direct = directUrlOf((String) url);
                if (direct != null) {
                    String routed = route(direct, headers);
                    proxied |= !routed.equals(direct);
                    json.put("url", routed);
                    changed = true;
                }
            } else if (url instanceof JSONArray) {
                JSONArray list = (JSONArray) url;
                for (int i = 0; i < list.length(); i++) {
                    String direct = directUrlOf(list.optString(i, null));
                    if (direct != null) {
                        String routed = route(direct, headers);
                        proxied |= !routed.equals(direct);
                        list.put(i, routed);
                        changed = true;
                    }
                }
            }
            if (!changed) return result;
            com.github.catvod.utils.DebugLog.line("Netdisk", proxied
                    ? "8096 加速代理已拆壳，改走本机分块并发代理"
                    : "8096 加速代理已拆壳，改为直连网盘");
            return json.toString();
        } catch (Exception e) {
            return result;
        }
    }

    private static String route(String direct, Map<String, String> headers) {
        String local = NetdiskChunkProxy.register(direct, headers);
        return local != null ? local : direct;
    }

    /** 载荷的 header 可能是 JSON 字符串，也可能是对象。 */
    static Map<String, String> headersOf(Object header) {
        Map<String, String> out = new LinkedHashMap<>();
        try {
            JSONObject obj = header instanceof JSONObject ? (JSONObject) header
                    : header instanceof String && ((String) header).trim().startsWith("{")
                    ? new JSONObject((String) header) : null;
            if (obj == null) return out;
            for (Iterator<String> it = obj.keys(); it.hasNext(); ) {
                String key = it.next();
                out.put(key, obj.optString(key, ""));
            }
        } catch (Exception ignored) {
            // 头解析失败不影响拆壳，最多上游因缺头返回 4xx
        }
        return out;
    }

    /** 是加速代理地址时返回其 url 参数指向的 http(s) 直链；否则返回 null。 */
    static String directUrlOf(String address) {
        if (address == null || !address.startsWith("http://127.0.0.1:" + ACCEL_PORT + "/")) return null;
        String query;
        try {
            URI uri = new URI(address);
            if (uri.getPort() != ACCEL_PORT) return null;
            String path = uri.getPath();
            if (!"/kaiser".equals(path) && !"/proxy".equals(path)) return null;
            query = uri.getRawQuery();
        } catch (Exception e) {
            return null;
        }
        if (query == null) return null;
        for (String pair : query.split("&")) {
            if (!pair.startsWith("url=")) continue;
            String decoded;
            try {
                decoded = URLDecoder.decode(pair.substring(4), StandardCharsets.UTF_8);
            } catch (IllegalArgumentException e) {
                return null;
            }
            return decoded.startsWith("http://") || decoded.startsWith("https://") ? decoded : null;
        }
        return null;
    }
}
