package com.github.catvod.utils;

import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentHashMap;
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
 *   -Dxiugou.debug.secrets=true      Cookie/Authorization 原样输出（默认打码成 ***）
 *   -Dxiugou.debug.ranges=true       带 Range 的分段下载逐条打印（默认按主机每 5 秒汇总一行）
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
 *   [DBG][HTTP] 分段下载 dl-c-zb-u.drive.quark.cn：5.0s 内 96 次 / 6.0 MB / 均 180ms / 206×96
 * </pre>
 */
public final class DebugLog {

    private static final boolean MASTER = bool("xiugou.debug", envBool("XIUGOU_DEBUG"));
    private static final boolean HTTP = MASTER && bool("xiugou.debug.http", true);
    private static final boolean RPC = MASTER && bool("xiugou.debug.rpc", true);
    private static final boolean FULL = MASTER && bool("xiugou.debug.full", false);
    // 默认打码：调试日志会被整段复制、贴进 issue / 聊天，网盘 Cookie 一贴出去就等于交出账号。
    private static final boolean SECRETS = MASTER && bool("xiugou.debug.secrets", false);
    // 网盘播放走载荷的多线程分段代理，每 64 KB 一个带 Range 的请求，一秒几十上百个；
    // 逐条打印会刷屏，还会让 Flutter 端的 debugPrint（每秒约 12 KB 限流）越积越多、
    // 播完很久还在往外吐。默认只按主机定时汇总，出错的那一条照旧立即打印。
    private static final boolean RANGES = MASTER && bool("xiugou.debug.ranges", false);
    private static final long BULK_WINDOW_MS = 5000;
    private static final int MAX = MASTER ? intProp("xiugou.debug.max", 4000) : 0;
    private static final AtomicLong SEQ = new AtomicLong();
    /** 正在进行的分段请求：id → 主机。响应 / 出错时取走。 */
    private static final Map<Long, String> BULK_INFLIGHT = new ConcurrentHashMap<>();
    /** 每个主机当前窗口的分段请求统计。 */
    private static final Map<String, BulkStats> BULK = new ConcurrentHashMap<>();
    private static volatile boolean bulkFlusherStarted;

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
        if (!RANGES && hasRange(headers)) {
            BULK_INFLIGHT.put(id, hostOf(url));
            startBulkFlusher();
            return;
        }
        out("HTTP", id, "--> " + method + " " + url);
        String hdr = formatHeaders(headers);
        if (!hdr.isEmpty()) out("HTTP", id, "    hdr: " + hdr);
        String text = render(body);
        if (!text.isEmpty()) out("HTTP", id, "    body(" + (body == null ? 0 : body.length) + "B): " + text);
    }

    public static void httpResponse(long id, int code, long costMs, String contentType, long length, byte[] body) {
        if (!HTTP) return;
        String bulkHost = BULK_INFLIGHT.remove(id);
        if (bulkHost != null) {
            BULK.computeIfAbsent(bulkHost, h -> new BulkStats()).add(code, costMs, length);
            return;
        }
        out("HTTP", id, "<-- " + code + " " + costMs + "ms "
                + (contentType == null ? "-" : contentType) + " "
                + (length >= 0 ? length + "B" : "chunked"));
        String text = render(body);
        if (!text.isEmpty()) out("HTTP", id, "    " + text);
    }

    public static void httpError(long id, Throwable t) {
        if (!HTTP) return;
        String bulkHost = BULK_INFLIGHT.remove(id);
        if (bulkHost != null) {
            BULK.computeIfAbsent(bulkHost, h -> new BulkStats()).fail();
            out("HTTP", id, "!! 分段下载 " + bulkHost + "：" + describe(t));
            return;
        }
        out("HTTP", id, "!! " + describe(t));
    }

    /** 把各主机当前窗口的分段下载统计各打一行；窗口内没有新请求的主机不打。后台线程每 5 秒调用一次。 */
    static void flushBulk() {
        for (Map.Entry<String, BulkStats> e : BULK.entrySet()) {
            String line = e.getValue().drain();
            if (line != null) out("HTTP", 0, "分段下载 " + e.getKey() + "：" + line);
        }
    }

    private static void startBulkFlusher() {
        if (bulkFlusherStarted) return;
        synchronized (BULK) {
            if (bulkFlusherStarted) return;
            Thread flusher = new Thread(() -> {
                while (true) {
                    try {
                        Thread.sleep(BULK_WINDOW_MS);
                    } catch (InterruptedException e) {
                        return;
                    }
                    flushBulk();
                }
            }, "debuglog-bulk");
            flusher.setDaemon(true);
            flusher.start();
            bulkFlusherStarted = true;
        }
    }

    private static boolean hasRange(Map<String, String> headers) {
        if (headers == null) return false;
        for (String name : headers.keySet()) {
            if ("range".equalsIgnoreCase(name)) return true;
        }
        return false;
    }

    /** 只取主机：汇总行不带路径和查询串（网盘直链的 auth_key / token 都在查询串里）。 */
    private static String hostOf(String url) {
        if (url == null) return "?";
        int start = url.indexOf("://");
        start = start < 0 ? 0 : start + 3;
        int end = start;
        while (end < url.length() && "/?#".indexOf(url.charAt(end)) < 0) end++;
        String host = url.substring(start, end);
        int at = host.lastIndexOf('@');
        if (at >= 0) host = host.substring(at + 1);
        return host.isEmpty() ? "?" : host;
    }

    /** 一个主机在一个汇总窗口里的分段请求统计。 */
    private static final class BulkStats {
        private int count;
        private int failures;
        private long bytes;
        private long costMs;
        private final Map<Integer, Integer> codes = new TreeMap<>();
        private long windowStart = System.nanoTime();

        synchronized void add(int code, long cost, long length) {
            count++;
            costMs += Math.max(0, cost);
            if (length > 0) bytes += length;
            codes.merge(code, 1, Integer::sum);
        }

        synchronized void fail() {
            failures++;
        }

        /** 取走本窗口的汇总并清零；本窗口没有新请求时返回 null。 */
        synchronized String drain() {
            long now = System.nanoTime();
            if (count == 0 && failures == 0) {
                windowStart = now;
                return null;
            }
            StringBuilder sb = new StringBuilder();
            sb.append(String.format(Locale.ROOT, "%.1fs 内 %d 次", (now - windowStart) / 1e9, count));
            if (failures > 0) sb.append("，失败 ").append(failures);
            sb.append(String.format(Locale.ROOT, " / %.1f MB", bytes / 1048576.0));
            if (count > 0) sb.append(" / 均 ").append(costMs / count).append("ms");
            if (!codes.isEmpty()) {
                sb.append(" /");
                for (Map.Entry<Integer, Integer> c : codes.entrySet()) {
                    sb.append(' ').append(c.getKey()).append('×').append(c.getValue());
                }
            }
            count = 0;
            failures = 0;
            bytes = 0;
            costMs = 0;
            codes.clear();
            windowStart = now;
            return sb.toString();
        }
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
