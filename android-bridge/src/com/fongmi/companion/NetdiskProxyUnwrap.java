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
 * 同一种加速代理协议不止出现在 8096：嗷呜（aowu）载荷把直链包成
 * {@code http://127.0.0.1:2525/proxy?url=<urlencoded>&size=512K&thread=16&remove=true}，
 * 2525 由它解出的 ARM64 {@code goproxy-android-arm64} 可执行文件提供，Windows 上同样起不来，
 * 播放器连 2525 被拒（§57，2026-11-01 实测木偶「摆渡原畫」）。所以按「协议特征」识别，而不是只认端口：
 * 回环地址 + {@code /kaiser} 或 {@code /proxy} + http(s) 的 url 参数，且（端口是 8096，或带
 * thread / size / chunk 任一加速参数）。
 *
 * 不碰的情况：companion 自己起的载荷代理端口（{@link GuardProxyServer#ownsPort}、本机分块代理端口），
 * 以及载荷 ProxyOrigin 形态 {@code /proxy?do=..&url=..}（带 do 参数，由
 * {@link GuardProxyServer#rewriteLocalProxyUrls} 处理）。
 */
public final class NetdiskProxyUnwrap {

    /** 载荷「GoProxy.startServer」硬编码的多线程代理端口；该端口不要求带加速参数。 */
    static final int ACCEL_PORT = 8096;

    /** 加速代理的特征参数：线程数 / 分块大小。 */
    private static final String[] ACCEL_PARAMS = {"thread", "size", "chunk"};

    private NetdiskProxyUnwrap() {
    }

    /**
     * 改写 playerContent 结果里的 url 字段（字符串，或多清晰度数组 [名称, 地址, ...]）。
     * 拆出的直链交给 {@link NetdiskChunkProxy} 登记成本机分块并发代理地址；代理未就绪时用直链。
     * 不是 JSON、没有命中加速代理时原样返回，不改动其它字段。
     */
    public static String unwrap(String result) {
        if (result == null || (!result.contains("127.0.0.1:") && !result.contains("localhost:"))
                || (!result.contains("/kaiser?") && !result.contains("/proxy?"))) {
            return result;
        }
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
                    ? "本地加速代理已拆壳，改走本机分块并发代理"
                    : "本地加速代理已拆壳，改为直连网盘");
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
        if (address == null
                || (!address.startsWith("http://127.0.0.1:") && !address.startsWith("http://localhost:"))) {
            return null;
        }
        String query;
        int port;
        try {
            URI uri = new URI(address);
            port = uri.getPort();
            String path = uri.getPath();
            if (!"/kaiser".equals(path) && !"/proxy".equals(path)) return null;
            query = uri.getRawQuery();
        } catch (Exception e) {
            return null;
        }
        if (query == null || port <= 0) return null;
        // companion 自己起的代理（载荷 ProxyOrigin 服务 / 本机分块代理）不拆
        if (port == NetdiskChunkProxy.localPort() || GuardProxyServer.ownsPort(port)) return null;
        String target = null;
        boolean accel = port == ACCEL_PORT;
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            String name = eq < 0 ? pair : pair.substring(0, eq);
            if ("do".equals(name)) return null; // ProxyOrigin 形态：交给 rewriteLocalProxyUrls
            for (String p : ACCEL_PARAMS) {
                if (p.equals(name)) accel = true;
            }
            if ("url".equals(name) && target == null && eq >= 0) {
                try {
                    target = URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
                } catch (IllegalArgumentException e) {
                    return null;
                }
            }
        }
        if (!accel || target == null) return null;
        return target.startsWith("http://") || target.startsWith("https://") ? target : null;
    }
}
