package com.fongmi.companion;

import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/**
 * Lightweight HTTP server exposing Spider execution RPCs to Flutter client.
 */
public class SpiderServer {

    private static final long DEFAULT_CALL_TIMEOUT_MS = 60_000L;
    private static final int MAX_INFLIGHT_CALLS = 64;

    private final DexSpiderLoader loader;
    private final int requestedPort;
    private final ThreadPoolExecutor callPool;
    private HttpServer server;
    private int boundPort;

    public SpiderServer(int port) {
        this.requestedPort = port;
        this.loader = new DexSpiderLoader();
        this.callPool = new ThreadPoolExecutor(
                0, MAX_INFLIGHT_CALLS, 60L, TimeUnit.SECONDS,
                new SynchronousQueue<Runnable>(),
                r -> {
                    Thread t = new Thread(r, "spider-call");
                    t.setDaemon(true);
                    return t;
                },
                new ThreadPoolExecutor.AbortPolicy());
    }

    public int start() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", requestedPort), 0);
        server.setExecutor(Executors.newCachedThreadPool());

        server.createContext("/health", new HealthHandler());
        server.createContext("/spider/load", new LoadHandler());
        server.createContext("/spider/call", new CallHandler());
        server.createContext("/shutdown", new ShutdownHandler());

        server.start();
        this.boundPort = server.getAddress().getPort();
        return this.boundPort;
    }

    public void stop() {
        if (server != null) {
            loader.clear();
            server.stop(1);
            server = null;
        }
        callPool.shutdownNow();
    }

    public int getBoundPort() {
        return boundPort;
    }

    private static void sendJsonResponse(HttpExchange exchange, int statusCode, String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.getResponseHeaders().set("Access-Control-Allow-Origin", "*");
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String readBody(HttpExchange exchange) throws IOException {
        try (InputStream is = exchange.getRequestBody();
             ByteArrayOutputStream baos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = is.read(buf)) != -1) {
                baos.write(buf, 0, n);
            }
            return baos.toString(StandardCharsets.UTF_8);
        }
    }

    private class HealthHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String resp = "{\"status\":\"ok\",\"version\":\"1.0.0\",\"javaVersion\":\""
                    + System.getProperty("java.version", "unknown")
                    + "\",\"port\":" + boundPort + "}";
            sendJsonResponse(exchange, 200, resp);
        }
    }

    private class ShutdownHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            sendJsonResponse(exchange, 200, "{\"msg\":\"shutting down\"}");
            // 响应流已经关闭；异步收尾无需额外延时占用客户端的退出等待预算。
            new Thread(() -> {
                stop();
                System.exit(0);
            }).start();
        }
    }

    private class LoadHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendJsonResponse(exchange, 405, "{\"error\":\"Method Not Allowed\"}");
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> payload = JsonCodec.parseObject(body);
            Map<String, String> map = new HashMap<>();
            for (Map.Entry<String, Object> entry : payload.entrySet()) {
                Object value = entry.getValue();
                map.put(entry.getKey(), value instanceof String ? (String) value : JsonCodec.stringify(value));
            }
            final String siteKey = map.getOrDefault("key", "");
            final String api = map.getOrDefault("api", "");
            final String ext = map.getOrDefault("ext", "");
            final String jar = map.getOrDefault("jar", "");

            long timeoutMs = resolveTimeoutMs(map);
            final String loadTag = "load@" + siteKey;
            String loadedKey = runWithWatchdog(exchange, loadTag, timeoutMs, () -> {
                ParseStage.begin(loadTag);
                Spider spider = loader.getSpider(siteKey, api, ext, jar);
                return spider.siteKey != null ? spider.siteKey : siteKey;
            });
            if (loadedKey == null) {
                return;
            }
            String resp = "{\"code\":0,\"msg\":\"loaded\",\"siteKey\":\"" + escapeJson(loadedKey) + "\"}";
            sendJsonResponse(exchange, 200, resp);
        }
    }

    private class CallHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendJsonResponse(exchange, 405, "{\"error\":\"Method Not Allowed\"}");
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> payload = JsonCodec.parseObject(body);
            Map<String, String> map = new HashMap<>();
            for (Map.Entry<String, Object> entry : payload.entrySet()) {
                Object value = entry.getValue();
                map.put(entry.getKey(), value instanceof String ? (String) value : JsonCodec.stringify(value));
            }
            String siteKey = map.getOrDefault("siteKey", "");
            String api = map.getOrDefault("api", "");
            String ext = map.getOrDefault("ext", "");
            String jar = map.getOrDefault("jar", "");
            String method = map.getOrDefault("method", "homeContent");

            long timeoutMs = resolveTimeoutMs(map);
            final String callTag = method + "@" + siteKey;
            String result = runWithWatchdog(exchange, callTag, timeoutMs,
                    () -> invokeSpiderCall(siteKey, api, ext, jar, method, map, callTag));
            if (result == null) {
                return;
            }

            String resp = "{\"code\":0,\"data\":" + (isJsonValue(result) ? result : "\"" + escapeJson(result) + "\"") + "}";
            sendJsonResponse(exchange, 200, resp);
        }
    }

    /**
     * 看门狗：spider 调用（jar 下载 / init / 网络请求）可能无超时挂死
     * （实测：夸克网盘 HTTP/2 读挂起 160s+，spider 内部无超时轮询），
     * 统一在独立 worker 线程执行，超时后放弃等待并返回明确的 timeout 错误，
     * 避免调用方（Flutter 客户端）被无限拖死。
     * 返回 null 表示错误响应已发送，调用方应直接 return。
     */
    private String runWithWatchdog(HttpExchange exchange, String tag, long timeoutMs, Callable<String> task) throws IOException {
        Future<String> future;
        try {
            future = callPool.submit(task);
        } catch (RejectedExecutionException ree) {
            System.err.println("[SpiderServer] reject " + tag + ": too many in-flight calls (>=" + MAX_INFLIGHT_CALLS + ")");
            sendJsonResponse(exchange, 503, "{\"code\":-3,\"error\":\"overloaded: too many in-flight spider calls\"}");
            return null;
        }
        try {
            return future.get(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException te) {
            boolean cancelled = future.cancel(true);
            System.err.println("[SpiderServer] watchdog timeout " + timeoutMs + "ms tag=" + tag
                    + " (cancel=" + cancelled + "; worker may still be blocked on network I/O)");
            sendJsonResponse(exchange, 504, "{\"code\":-2,\"error\":\"timeout\",\"tag\":\"" + escapeJson(tag)
                    + "\",\"timeoutMs\":" + timeoutMs + "}");
            return null;
        } catch (ExecutionException ee) {
            Throwable cause = ee.getCause() != null ? ee.getCause() : ee;
            cause.printStackTrace();
            // 响应分三层：error=面向用户的人话；stage=内部阶段；detail=技术细节（只在日志/探针用）
            ParseStage.Failure failure = ParseStage.forTag(tag);
            String stage = failure != null ? failure.stage : ParseStage.CALL;
            String detail = failure != null ? failure.detail : String.valueOf(cause.getMessage());
            sendJsonResponse(exchange, 500, "{\"code\":-1,\"error\":\"站点暂不可用\",\"stage\":\""
                    + escapeJson(stage) + "\",\"detail\":\"" + escapeJson(detail) + "\"}");
            return null;
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            sendJsonResponse(exchange, 500, "{\"code\":-1,\"error\":\"interrupted\"}");
            return null;
        }
    }

    /** 宽容解析整型参数：缺失或非法时用默认值，避免调用方为可选参数报错。 */
    private static int parseInt(String raw, int fallback) {
        if (raw == null || raw.trim().isEmpty()) {
            return fallback;
        }
        try {
            return Integer.parseInt(raw.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static long resolveTimeoutMs(Map<String, String> map) {
        String raw = map.get("timeoutMs");
        if (raw != null && !raw.trim().isEmpty()) {
            try {
                long v = Long.parseLong(raw.trim());
                if (v > 0) {
                    return v;
                }
            } catch (NumberFormatException ignored) {
            }
        }
        return DEFAULT_CALL_TIMEOUT_MS;
    }

    private static boolean isJsonValue(String s) {
        return s != null && (s.startsWith("{") || s.startsWith("["));
    }

    private String invokeSpiderCall(String siteKey, String api, String ext, String jar, String method,
                                    Map<String, String> map, String stageTag) throws Exception {
        // 每次调用先清掉本线程上一次的阶段记录：worker 线程是复用的，否则会读到残留
        ParseStage.begin(stageTag);
        // 自检总开关：不绑定站点，运行期改写体检开关（设置页切换开关时下发）。
        if ("selfCheckConfig".equals(method)) {
            boolean on = Boolean.parseBoolean(map.getOrDefault("enabled", "false"));
            com.fongmi.companion.selfcheck.PayloadInspector.setEnabled(on);
            return "{\"enabled\":" + on + "}";
        }
        // 逐站自检不绑定单个站点：body 里带 "sites"（JSON 数组）即可。
        // 必须在 getSpider 之前分流，否则会对空 api 建一个 SpiderNull。
        if ("selfCheck".equals(method)) {
            // 开关关闭时明确拒绝：不能"看起来跑过一轮"，否则会误判成站点真的没问题。
            if (!com.fongmi.companion.selfcheck.PayloadInspector.isEnabled()) {
                throw new IllegalStateException("self-check disabled");
            }
            return com.fongmi.companion.selfcheck.SiteSelfCheck.run(
                    loader,
                    map.getOrDefault("sites", "[]"),
                    parseInt(map.get("maxSites"), 0),
                    parseInt(map.get("maxCategories"), 3),
                    parseInt(map.get("perSiteTimeout"), 30));
        }
        Spider spider = loader.getSpider(siteKey, api, ext, jar);
        // 载荷没加载起来时**不再静默返回空串**：那会让调用方看到 {"code":0,"data":""}，
        // 误以为「站点没内容」。这里升级为带阶段的错误（阶段由 getSpider 内部记录）。
        if (spider instanceof SpiderNull) {
            ParseStage.Failure failure = ParseStage.current();
            String stage = failure != null ? failure.stage : ParseStage.CLASS;
            String detail = failure != null ? failure.detail : "payload not loadable";
            ParseStage.fail(stage, detail);
            // 抛给 RPC 层的 message 保持「人话」；技术细节走 ParseStage → 响应的 detail 字段与日志
            throw new IllegalStateException("站点暂不可用");
        }
        String result;
        switch (method) {
            case "homeContent": {
                boolean filter = Boolean.parseBoolean(map.getOrDefault("filter", "true"));
                result = spider.homeContent(filter);
                break;
            }
            case "homeVideoContent": {
                result = spider.homeVideoContent();
                break;
            }
            case "categoryContent": {
                String tid = map.getOrDefault("tid", "");
                String pg = map.getOrDefault("pg", "1");
                boolean filter = Boolean.parseBoolean(map.getOrDefault("filter", "true"));
                result = spider.categoryContent(tid, pg, filter, new HashMap<>());
                break;
            }
            case "detailContent": {
                String id = map.getOrDefault("id", "");
                List<String> ids = Collections.singletonList(id);
                result = spider.detailContent(ids);
                break;
            }
            case "searchContent": {
                String wd = map.getOrDefault("wd", map.getOrDefault("key", ""));
                boolean quick = Boolean.parseBoolean(map.getOrDefault("quick", "false"));
                String pg = map.getOrDefault("pg", "1");
                result = spider.searchContent(wd, quick, pg);
                break;
            }
            case "playerContent": {
                String flag = map.getOrDefault("flag", "");
                String id = map.getOrDefault("id", "");
                result = spider.playerContent(flag, id, new ArrayList<>());
                break;
            }
            case "liveContent": {
                String url = map.getOrDefault("url", map.getOrDefault("id", ""));
                result = spider.liveContent(url);
                break;
            }
            default:
                result = "{}";
                break;
        }
        // 播放地址改写：载荷把 m3u8 包成 http://127.0.0.1:<port>/proxy?do=..&url=..，
        // 而 mv p/media_kit 会在第一个 & 处截断 URL（实测请求行只剩 ?do=m3u8），
        // 载荷拿不到 url → 空流 → 播放器报 "Failed to recognize file format."。
        // 统一改写成 `/proxy/<base64url>`，播放器与 curl 都可用。
        return result != null ? GuardProxyServer.rewriteLocalProxyUrls(result) : "";
    }

    private static String escapeJson(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }

    /**
     * Minimal JSON key-value string extractor to avoid extra dependencies.
     */
    static class SimpleJson {
        public static Map<String, String> parseObject(String json) {
            Map<String, String> map = new HashMap<>();
            if (json == null || json.trim().isEmpty()) return map;
            json = json.trim();
            if (json.startsWith("{") && json.endsWith("}")) {
                json = json.substring(1, json.length() - 1).trim();
            }
            // Simple regex parser for top level string/primitive props
            java.util.regex.Pattern pattern = java.util.regex.Pattern.compile("\"([^\"]+)\"\\s*:\\s*(\"[^\"]*\"|true|false|[0-9\\.]+)");
            java.util.regex.Matcher matcher = pattern.matcher(json);
            while (matcher.find()) {
                String key = matcher.group(1);
                String val = matcher.group(2);
                if (val.startsWith("\"") && val.endsWith("\"")) {
                    val = val.substring(1, val.length() - 1);
                }
                map.put(key, val);
            }
            return map;
        }
    }
}
