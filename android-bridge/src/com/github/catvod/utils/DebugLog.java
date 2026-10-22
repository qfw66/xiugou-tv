package com.github.catvod.utils;

import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 统一调试日志（默认关闭，零开销）。
 *
 * <p>开关：
 * <pre>
 *   -Dxiugou.debug=true              总开关（也可用环境变量 XIUGOU_DEBUG=1）
 *   -Dxiugou.debug.http=false        单独关闭 HTTP 明细
 *   -Dxiugou.debug.rpc=false         单独关闭 RPC 明细
 *   -Dxiugou.debug.full=true         不截断响应体（默认每段最多 4000 字符）
 *   -Dxiugou.debug.max=8000          自定义截断长度
 *   -Dxiugou.debug.secrets=false     Cookie/Authorization 打码（默认原样输出）
 * </pre>
 *
 * <p>输出统一带 {@code [DBG]} 前缀，方便在控制台过滤：
 * <pre>
 *   [DBG][HTTP #12] --> GET https://api.example.com/list?page=1
 *   [DBG][HTTP #12]     hdr: User-Agent=... | Referer=...
 *   [DBG][HTTP #12] <-- 200 312ms application/json 18234B
 *   [DBG][HTTP #12]     {"code":0,"data":[...]}
 *   [DBG][RPC  #7] --> categoryContent site=seed api=csp_SeedhubGuard tid=1 pg=1
 *   [DBG][RPC  #7] <-- 1234ms 18234B
 * </pre>
 */
public final class DebugLog {

    private static final boolean MASTER = bool("xiugou.debug", envBool("XIUGOU_DEBUG"));
    private static final boolean HTTP = MASTER && bool("xiugou.debug.http", true);
    private static final boolean RPC = MASTER && bool("xiugou.debug.rpc", true);
    private static final boolean FULL = MASTER && bool("xiugou.debug.full", false);
    private static final boolean SECRETS = MASTER && bool("xiugou.debug.secrets", true);
    private static final int MAX = MASTER ? intProp("xiugou.debug.max", 4000) : 0;
    private static final AtomicLong SEQ = new AtomicLong();

    private DebugLog() {
    }

    public static boolean enabled() {
        return MASTER;
    }

    public static boolean httpEnabled() {
        return HTTP;
    }

    public static boolean rpcEnabled() {
        return RPC;
    }

    public static long nextId() {
        return MASTER ? SEQ.incrementAndGet() : 0;
    }

    public static int maxChars() {
        return MAX;
    }

    // ==================================================================================
    // HTTP
    // ==================================================================================

    public static void httpRequest(long id, String method, String url, Map<String, String> headers, byte[] body) {
        if (!HTTP) return;
        out("HTTP", id, "--> " + method + " " + url);
        String hdr = formatHeaders(headers);
        if (!hdr.isEmpty()) out("HTTP", id, "    hdr: " + hdr);
        String text = render(body);
        if (!text.isEmpty()) out("HTTP", id, "    body(" + (body == null ? 0 : body.length) + "B): " + text);
    }

    public static void httpResponse(long id, int code, long costMs, String contentType, long length, byte[] body) {
        if (!HTTP) return;
        out("HTTP", id, "<-- " + code + " " + costMs + "ms "
                + (contentType == null ? "-" : contentType) + " "
                + (length >= 0 ? length + "B" : "chunked"));
        String text = render(body);
        if (!text.isEmpty()) out("HTTP", id, "    " + text);
    }

    public static void httpError(long id, Throwable t) {
        if (!HTTP) return;
        out("HTTP", id, "!! " + describe(t));
    }

    // ==================================================================================
    // RPC
    // ==================================================================================

    public static void rpcStart(long id, String method, String siteKey, String api, String ext, String jar,
            Map<String, String> params) {
        if (!RPC) return;
        out("RPC", id, "--> " + method + " site=" + safe(siteKey) + " api=" + safe(api));
        if (ext != null && !ext.isEmpty()) out("RPC", id, "    ext(" + ext.length() + "B): " + truncate(ext));
        if (jar != null && !jar.isEmpty()) out("RPC", id, "    jar: " + tail(jar, 90));
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : params.entrySet()) {
            String k = e.getKey();
            if ("siteKey".equals(k) || "api".equals(k) || "ext".equals(k) || "jar".equals(k)
                    || "method".equals(k) || "timeoutMs".equals(k)) {
                continue;
            }
            if (sb.length() > 0) sb.append(' ');
            sb.append(k).append('=').append(truncate(e.getValue()));
        }
        if (sb.length() > 0) out("RPC", id, "    " + sb);
    }

    public static void rpcResult(long id, String method, String result) {
        if (!RPC) return;
        int size = result == null ? 0 : result.length();
        out("RPC", id, "<-- " + method + " " + size + "B");
        if (size > 0) out("RPC", id, "    " + truncate(result));
    }

    // ==================================================================================
    // 工具
    // ==================================================================================

    public static void line(String tag, String msg) {
        if (!MASTER) return;
        System.out.println("[DBG][" + tag + "] " + msg);
    }

    public static String truncate(String text) {
        if (text == null) return "";
        // 响应体里的换行会把一条日志撑成几十行，统一转义成 \n，保证「一条日志一行」。
        String oneLine = text.replace("\r\n", "\\n").replace("\n", "\\n")
                .replace("\r", "\\n").replace("\t", "\\t");
        if (FULL || oneLine.length() <= MAX) return oneLine;
        return oneLine.substring(0, MAX) + "…(+" + (oneLine.length() - MAX) + " chars)";
    }

    private static void out(String tag, long id, String msg) {
        System.out.println("[DBG][" + tag + (id > 0 ? " #" + id : "") + "] " + msg);
    }

    private static String formatHeaders(Map<String, String> headers) {
        if (headers == null || headers.isEmpty()) return "";
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if (sb.length() > 0) sb.append(" | ");
            String value = e.getValue();
            if (!SECRETS && isSecret(e.getKey())) value = "***";
            sb.append(e.getKey()).append('=').append(value == null ? "" : truncate(value));
        }
        return sb.toString();
    }

    private static boolean isSecret(String name) {
        String n = name == null ? "" : name.toLowerCase(Locale.ROOT);
        return n.contains("cookie") || n.contains("authorization") || n.contains("token")
                || n.contains("secret") || n.contains("password");
    }

    /** 文本按 UTF-8 原样输出；二进制只打十六进制头。 */
    private static String render(byte[] body) {
        if (body == null || body.length == 0) return "";
        String text = new String(body, StandardCharsets.UTF_8);
        int broken = 0;
        int probe = Math.min(text.length(), 256);
        for (int i = 0; i < probe; i++) {
            if (text.charAt(i) == '\uFFFD') broken++;
        }
        if (broken > 2) return "hex:" + hex(body, Math.min(body.length, 64));
        return truncate(text);
    }

    private static String hex(byte[] data, int limit) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < limit; i++) {
            sb.append(String.format("%02x", data[i] & 0xff));
        }
        if (data.length > limit) sb.append("…");
        return sb.toString();
    }

    private static String describe(Throwable t) {
        if (t == null) return "unknown";
        Throwable cause = t.getCause() != null ? t.getCause() : t;
        return cause.getClass().getSimpleName() + ": " + cause.getMessage();
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }

    private static String tail(String value, int count) {
        if (value == null) return "";
        return value.length() <= count ? value : "…" + value.substring(value.length() - count);
    }

    private static boolean bool(String key, boolean fallback) {
        String value = System.getProperty(key);
        if (value == null || value.trim().isEmpty()) return fallback;
        return "true".equalsIgnoreCase(value.trim()) || "1".equals(value.trim())
                || "yes".equalsIgnoreCase(value.trim());
    }

    private static boolean envBool(String key) {
        String value = System.getenv(key);
        return value != null && ("1".equals(value.trim()) || "true".equalsIgnoreCase(value.trim()));
    }

    private static int intProp(String key, int fallback) {
        try {
            String value = System.getProperty(key);
            return value == null ? fallback : Integer.parseInt(value.trim());
        } catch (Throwable t) {
            return fallback;
        }
    }
}
