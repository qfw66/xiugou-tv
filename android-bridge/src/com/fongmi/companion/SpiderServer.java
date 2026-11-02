package com.fongmi.companion;

import com.fongmi.companion.agent.CallRegistry;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;
import com.github.catvod.utils.DebugLog;
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
    /** 客户端给的看门狗超时上限：全站体检按站数放大预算，30 分钟足够覆盖单批。 */
    private static final long MAX_CALL_TIMEOUT_MS = 30 * 60_000L;
    /** /ui/events 长轮询等待上限。 */
    private static final long MAX_POLL_WAIT_MS = 60_000L;
    /** 无 rpcId 时生成服务端唯一后缀的序号，见 {@link #rpcTagOf}。 */
    private static final java.util.concurrent.atomic.AtomicLong SERVER_RPC_SEQ =
            new java.util.concurrent.atomic.AtomicLong();
    /** 服务端生成标签的分隔符：按粗粒度 tag 取消时据此匹配同族标签。 */
    static final String SERVER_RPC_SUFFIX = "#srv";

    private final DexSpiderLoader loader;
    private final int requestedPort;
    private final ThreadPoolExecutor callPool;
    private HttpServer server;
    private java.util.concurrent.ExecutorService httpExecutor;
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
        // 守护线程 + 显式 shutdown：HttpServer 自己不会关闭外部传入的 executor，
        // 非守护线程会让 JVM 在「主逻辑已结束」后仍被吊住。
        server.setExecutor(httpExecutor = Executors.newCachedThreadPool(r -> {
            Thread t = new Thread(r, "spider-http");
            t.setDaemon(true);
            return t;
        }));

        server.createContext("/health", guarded(new HealthHandler()));
        server.createContext("/spider/load", guarded(new LoadHandler()));
        server.createContext("/spider/call", guarded(new CallHandler()));
        server.createContext("/spider/cancel", guarded(new CancelHandler()));
        server.createContext("/spider/reset", guarded(new ResetHandler()));
        server.createContext("/shutdown", guarded(new ShutdownHandler()));
        // 载荷弹窗 / Toast 等界面事件（长轮询）与用户操作回放，见 ui.UiBridge
        server.createContext("/ui/events", guarded(new UiEventsHandler()));
        server.createContext("/ui/input", guarded(new UiInputHandler()));
        com.fongmi.companion.ui.UiBridge.install();
        // 网盘直链分块并发代理（替代载荷 8096 加速代理），见 docs/NETDISK_PLAYBACK_PLAN.md
        server.createContext(NetdiskChunkProxy.PREFIX, new NetdiskChunkProxy());

        server.start();
        this.boundPort = server.getAddress().getPort();
        NetdiskChunkProxy.setLocalPort(this.boundPort);
        return this.boundPort;
    }

    /** 请求体超过 {@link #MAX_BODY_BYTES}：统一包装层据此回 413。 */
    private static final class BodyTooLargeException extends IOException {
        BodyTooLargeException() {
            super("请求体超过 8 MB");
        }
    }

    /**
     * 统一包装：任何 handler 抛出的异常都回 500（请求体超限回 413），且无论成败都关闭 exchange，
     * 避免连接与请求体流在异常路径上滞留。响应头已发出时只记日志、不再重复写头。
     */
    private static HttpHandler guarded(HttpHandler inner) {
        return exchange -> {
            try {
                inner.handle(exchange);
            } catch (Throwable t) {
                System.err.println("[SpiderServer] handler error " + exchange.getRequestURI().getPath() + ": " + t);
                if (exchange.getResponseCode() == -1) {
                    try {
                        if (t instanceof BodyTooLargeException) {
                            sendJsonResponse(exchange, 413, "{\"code\":-1,\"error\":\"payload too large\"}");
                        } else {
                            sendJsonResponse(exchange, 500, "{\"code\":-1,\"error\":\"" + escapeJson(String.valueOf(t)) + "\"}");
                        }
                    } catch (Throwable ignored) {
                    }
                }
            } finally {
                exchange.close();
            }
        };
    }

    /** 当前占用 callPool 的 worker 数：持续等于上限说明有不可中止的阻塞，客户端可据此重启 companion。 */
    public int activeCalls() {
        return callPool.getActiveCount();
    }

    public void stop() {
        if (server != null) {
            loader.clear();
            server.stop(1);
            server = null;
        }
        if (httpExecutor != null) {
            httpExecutor.shutdownNow();
            httpExecutor = null;
        }
        callPool.shutdownNow();
        com.fongmi.companion.ui.UiBridge.get().reset();
        // 停机时把还在 socket read 上的请求一并掐断，别把 Cancel 掉的引用留给下一个实例。
        CallRegistry.clear();
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

    /** 请求体上限：本地 RPC 最大的是全站体检列表，几 MB 足够。 */
    private static final int MAX_BODY_BYTES = 8 << 20;

    private static String readBody(HttpExchange exchange) throws IOException {
        try (InputStream is = exchange.getRequestBody();
             ByteArrayOutputStream baos = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n;
            while ((n = is.read(buf)) != -1) {
                if (baos.size() + n > MAX_BODY_BYTES) throw new BodyTooLargeException();
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
                    + "\",\"port\":" + boundPort
                    + ",\"activeCalls\":" + callPool.getActiveCount()
                    + ",\"maxCalls\":" + MAX_INFLIGHT_CALLS + "}";
            sendJsonResponse(exchange, 200, resp);
        }
    }

    /**
     * 换配置时由客户端调用：释放旧配置的全部 spider、类加载器、代理端口与密码服务子进程。
     * 不重置的话这些只增不减（元空间、python 子进程、9978-10000 端口池都会被耗尽）。
     */
    private class ResetHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendJsonResponse(exchange, 405, "{\"error\":\"Method Not Allowed\"}");
                return;
            }
            readBody(exchange);
            int released = loader.clear();
            com.fongmi.companion.hardshell.PayloadCryptoService.reset();
            com.fongmi.companion.guard.GuardCryptoService.reset();
            System.out.println("[SpiderServer] 配置已切换，释放 spider " + released + " 个");
            sendJsonResponse(exchange, 200, "{\"code\":0,\"released\":" + released + "}");
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

    private class UiEventsHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            Map<String, String> query = parseQuery(exchange.getRequestURI().getRawQuery());
            long after = parseLong(query.get("after"), -1L);
            long waitMs = Math.max(0L, Math.min(MAX_POLL_WAIT_MS, parseLong(query.get("wait"), 25_000L)));
            try {
                sendJsonResponse(exchange, 200, com.fongmi.companion.ui.UiBridge.get().poll(after, waitMs));
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                sendJsonResponse(exchange, 503, "{\"error\":\"interrupted\"}");
            }
        }
    }

    private class UiInputHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendJsonResponse(exchange, 405, "{\"error\":\"Method Not Allowed\"}");
                return;
            }
            boolean accepted = com.fongmi.companion.ui.UiBridge.get().input(JsonCodec.parseObject(readBody(exchange)));
            sendJsonResponse(exchange, 200, "{\"code\":0,\"accepted\":" + accepted + "}");
        }
    }

    private static Map<String, String> parseQuery(String raw) {
        Map<String, String> out = new HashMap<>();
        if (raw == null || raw.isEmpty()) return out;
        for (String pair : raw.split("&")) {
            int eq = pair.indexOf('=');
            String key = eq < 0 ? pair : pair.substring(0, eq);
            String value = eq < 0 ? "" : pair.substring(eq + 1);
            out.put(java.net.URLDecoder.decode(key, StandardCharsets.UTF_8),
                    java.net.URLDecoder.decode(value, StandardCharsets.UTF_8));
        }
        return out;
    }

    private static long parseLong(String value, long fallback) {
        if (value == null) return fallback;
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
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
            String loadedKey = runWithWatchdog(exchange, loadTag, rpcTagOf(loadTag, map.get("rpcId")), timeoutMs, () -> {
                Spider spider = requireUsableSpider(loader.getSpider(siteKey, api, ext, jar));
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
            long dbg = DebugLog.rpcEnabled() ? DebugLog.nextId() : 0;
            DebugLog.rpcStart(dbg, method, siteKey, api, ext, jar, map);
            long dialogsBefore = com.fongmi.companion.ui.UiBridge.shownCount();
            String result = runWithWatchdog(exchange, callTag, rpcTagOf(callTag, map.get("rpcId")), timeoutMs,
                    () -> invokeSpiderCall(siteKey, api, ext, jar, method, map, callTag));
            if (result == null) {
                return;
            }
            DebugLog.rpcResult(dbg, method, result);

            // 空结果不等于成功：detail/player 必须返回内容，空串代表源方没有下发
            // （典型：上游 panonline=false，网盘在线模式被关掉）。以前包装成 code:0 + data:""，
            // 客户端只能归到「解析失败」，把用户引去查 Cookie —— 实际 CK 是好的。
            // home/search 的空列表是正常结果，不能套用这条。
            String trimmed = result == null ? "" : result.trim();
            boolean mustHaveContent = "detailContent".equals(method) || "playerContent".equals(method);
            if (mustHaveContent && (trimmed.isEmpty() || "{}".equals(trimmed) || "[]".equals(trimmed))) {
                // The payload asked the user something (e.g. 海绵「选择任意网盘扫码后即可播放」) and got no answer:
                // retrying would only pop the same dialog again.
                boolean askedUser = com.fongmi.companion.ui.UiBridge.shownCount() > dialogsBefore;
                String stage = askedUser ? "interaction" : "empty";
                String detail = askedUser
                        ? "站源需要先在弹出的窗口里完成操作（如扫码登录网盘）后才能继续"
                        : "站点未返回内容（源方可能已关闭网盘在线模式）";
                sendJsonResponse(exchange, 200,
                        "{\"code\":-1,\"stage\":\"" + stage + "\",\"detail\":\"" + escapeJson(detail) + "\"}");
                return;
            }
            String resp = "{\"code\":0,\"data\":" + (isJsonValue(result) ? result : "\"" + escapeJson(result) + "\"") + "}";
            sendJsonResponse(exchange, 200, resp);
        }
    }

    /**
     * POST /spider/cancel —— 客户端主动中止一次 RPC。
     *
     * <p>只断 HTTP 连接是不够的：Dio 侧 cancel 掉的是 Flutter 与 companion 之间那条连接，
     * worker 线程仍在 jar 内部的 OkHttp 同步请求上阻塞，继续占着 {@code callPool} 的槽。
     * 这里按取消标签调到 {@code Call.cancel()}，socket 立即关闭，阻塞中的请求以
     * IOException 退出，线程归还。
     *
     * <p>入参优先用 {@code rpcId}（客户端生成的不透明 id）；没带则退回 {@code tag}
     * （形如 {@code search@siteKey}），粒度更粗但同样生效。
     */
    private static class CancelHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
                sendJsonResponse(exchange, 405, "{\"error\":\"Method Not Allowed\"}");
                return;
            }
            String body = readBody(exchange);
            Map<String, Object> payload = JsonCodec.parseObject(body);
            String tag = text(payload.get("rpcId"));
            if (tag.isEmpty()) {
                tag = text(payload.get("tag"));
            }
            // 只给了粗粒度 tag 时，连同服务端为无 rpcId 请求生成的同族标签一起取消
            int cancelled = payload.get("rpcId") instanceof String && !tag.isEmpty() && tag.equals(text(payload.get("rpcId")))
                    ? CallRegistry.cancel(tag)
                    : CallRegistry.cancelFamily(tag, SERVER_RPC_SUFFIX);
            DebugLog.line("RPC", "cancel tag=" + tag + " cancelled=" + cancelled);
            sendJsonResponse(exchange, 200, "{\"code\":0,\"tag\":\"" + escapeJson(tag)
                    + "\",\"cancelled\":" + cancelled + "}");
        }

        private static String text(Object value) {
            return value instanceof String ? ((String) value).trim() : "";
        }
    }

    /**
     * 取消标签：调用方给了 {@code rpcId} 就只用这个不透明 id —— 同站同方法的并发调用
     * （比如连着搜两个词）不会互相误伤；没给就退回 {@code fallbackTag}，粒度变粗但依然可取消。
     */
    private static String rpcTagOf(String fallbackTag, String rpcId) {
        // 没给 rpcId 时生成唯一后缀：同标签并发时，先结束的 worker 收尾 unbind 不会取消另一次的在途请求
        return rpcId == null || rpcId.trim().isEmpty()
                ? fallbackTag + SERVER_RPC_SUFFIX + SERVER_RPC_SEQ.incrementAndGet()
                : rpcId.trim();
    }

    /**
     * 看门狗：spider 调用（jar 下载 / init / 网络请求）可能无超时挂死
     * （实测：夸克网盘 HTTP/2 读挂起 160s+，spider 内部无超时轮询），
     * 统一在独立 worker 线程执行，超时后放弃等待并返回明确的 timeout 错误，
     * 避免调用方（Flutter 客户端）被无限拖死。
     * 返回 null 表示错误响应已发送，调用方应直接 return。
     *
     * <p>{@code rpcTag} 是取消标签（见 {@link CallRegistry}）：与 {@code tag} 分开传，
     * 让日志继续用可读标签（{@code homeContent@xx}），取消则用「同站同方法也不会串味」的唯一标签。
     */
    private String runWithWatchdog(HttpExchange exchange, String tag, String rpcTag, long timeoutMs, Callable<String> task) throws IOException {
        Future<String> future;
        try {
            future = callPool.submit(() -> {
                String previous = CallRegistry.bind(rpcTag);
                ParseStage.begin(rpcTag);
                try {
                    return task.call();
                } catch (Throwable error) {
                    throw new SpiderWorkerFailure(error, ParseStage.current());
                } finally {
                    ParseStage.clearFailure();
                    ParseStage.clearTag(rpcTag);
                    CallRegistry.unbind(previous);
                }
            });
        } catch (RejectedExecutionException ree) {
            System.err.println("[SpiderServer] reject " + tag + ": too many in-flight calls (>=" + MAX_INFLIGHT_CALLS + ")");
            sendJsonResponse(exchange, 503, "{\"code\":-3,\"error\":\"overloaded: too many in-flight spider calls\"}");
            return null;
        }
        try {
            return future.get(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException te) {
            // 先掐 socket，再 interrupt：只做 future.cancel(true) 时，卡在 OkHttp 同步
            // execute() 的 worker 吃不到 interrupt（JDK 语义），会长期占着 callPool 的槽。
            int aborted = CallRegistry.cancel(rpcTag);
            boolean cancelled = future.cancel(true);
            System.err.println("[SpiderServer] watchdog timeout " + timeoutMs + "ms tag=" + tag
                    + " (cancel=" + cancelled + "; abortedHttpCalls=" + aborted
                    + (aborted == 0 ? "; worker may still be blocked on non-OkHttp I/O" : "") + ")");
            DebugLog.line("RPC", "watchdog timeout " + timeoutMs + "ms tag=" + tag);
            sendJsonResponse(exchange, 504, "{\"code\":-2,\"error\":\"timeout\",\"tag\":\"" + escapeJson(tag)
                    + "\",\"timeoutMs\":" + timeoutMs + "}");
            return null;
        } catch (ExecutionException ee) {
            Throwable worker = ee.getCause() != null ? ee.getCause() : ee;
            ParseStage.Failure failure = worker instanceof SpiderWorkerFailure
                    ? ((SpiderWorkerFailure) worker).failure : null;
            Throwable cause = worker instanceof SpiderWorkerFailure ? worker.getCause() : worker;
            cause.printStackTrace();
            DebugLog.line("RPC", "error " + tag + ": " + cause);
            // 响应分三层：error=面向用户的人话；stage=内部阶段；detail=技术细节（只在日志/探针用）
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
                    return Math.min(v, MAX_CALL_TIMEOUT_MS);
                }
            } catch (NumberFormatException ignored) {
            }
        }
        return DEFAULT_CALL_TIMEOUT_MS;
    }

    private static boolean isJsonValue(String s) {
        return s != null && (s.startsWith("{") || s.startsWith("["));
    }

    private static final class SpiderWorkerFailure extends Exception {
        final ParseStage.Failure failure;
        SpiderWorkerFailure(Throwable cause, ParseStage.Failure failure) {
            super(cause);
            this.failure = failure;
        }
    }

    private static Spider requireUsableSpider(Spider spider) {
        if (spider == null || spider instanceof SpiderNull) {
            if (ParseStage.current() == null) ParseStage.fail(ParseStage.CLASS, "payload not loadable");
            throw new IllegalStateException("站点暂不可用");
        }
        return spider;
    }

    private String invokeSpiderCall(String siteKey, String api, String ext, String jar, String method,
                                    Map<String, String> map, String stageTag) throws Exception {
        // The watchdog owns this worker's unique RPC diagnostic scope.
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
        Spider spider = requireUsableSpider(loader.getSpider(siteKey, api, ext, jar));
        ParseStage.clearFailure();
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
            case "action": {
                // FongMi 的 Spider.action：列表项带 action 字段时，点击触发它（配置中心的扫码 / 输入设置）
                result = spider.action(map.getOrDefault("action", ""));
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
        // invariant: an upstream error page swallowed by the payload must not become a valid empty listing.
        ParseStage.Failure upstream = ParseStage.current();
        if (upstream != null && ParseStage.UPSTREAM.equals(upstream.stage) && isEmptyListing(method, result)) {
            throw new IllegalStateException(upstream.detail);
        }
        // 播放地址改写：载荷把 m3u8 包成 http://127.0.0.1:<port>/proxy?do=..&url=..，
        // 而 mv p/media_kit 会在第一个 & 处截断 URL（实测请求行只剩 ?do=m3u8），
        // 载荷拿不到 url → 空流 → 播放器报 "Failed to recognize file format."。
        // 统一改写成 `/proxy/<base64url>`，播放器与 curl 都可用。
        // 网盘直链：载荷把直链包进 8096 多线程代理（ARM 原生库，Windows 起不来），拆壳直连。
        if (result != null && "playerContent".equals(method)) {
            result = NetdiskProxyUnwrap.unwrap(result);
        }
        return result != null ? GuardProxyServer.rewriteLocalProxyUrls(result) : "";
    }

    private static boolean isEmptyListing(String method, String result) {
        boolean home = "homeContent".equals(method);
        if (!home && !"categoryContent".equals(method) && !"searchContent".equals(method)) return false;
        String text = result == null ? "" : result.trim();
        if (text.isEmpty() || "{}".equals(text)) return true;
        try {
            org.json.JSONObject json = new org.json.JSONObject(text);
            org.json.JSONArray list = json.optJSONArray("list");
            org.json.JSONArray classes = json.optJSONArray("class");
            return (list == null || list.length() == 0) && (!home || classes == null || classes.length() == 0);
        } catch (Exception ignored) {
            return false;
        }
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
