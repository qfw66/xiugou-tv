package com.fongmi.companion;

import com.fongmi.companion.py.PyProxyResponse;
import com.fongmi.companion.py.PySpider;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import java.io.IOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/** Same-port HTTP view of registered Python instances. Never loads scripts from request parameters. */
public final class ScriptProxyHandler implements HttpHandler {
    private static final Set<String> HOP_HEADERS = Set.of("connection", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade");
    private final DexSpiderLoader loader;
    private final ExecutorService workers;

    public ScriptProxyHandler(DexSpiderLoader loader, ExecutorService workers) {
        this.loader = loader;
        this.workers = workers;
    }

    @Override
    public void handle(HttpExchange exchange) throws IOException {
        Future<PyProxyResponse> pending = null;
        ProxyCall call = null;
        String token = "";
        String siteKey = "";
        try {
            String path = exchange.getRequestURI().getPath();
            if (!"/script-proxy".equals(path) && !path.startsWith("/script-proxy/")) {
                error(exchange, 404);
                return;
            }
            String method = exchange.getRequestMethod();
            if (!method.equals("GET") && !method.equals("HEAD")) {
                exchange.getResponseHeaders().set("Allow", "GET, HEAD");
                error(exchange, 405);
                return;
            }
            Map<String, String> params = query(exchange.getRequestURI().getRawQuery());
            token = params.remove("token");
            siteKey = params.remove("siteKey");
            String kind = params.remove("do");
            PySpider script = loader.registeredScript(token, siteKey);
            if (!"py".equals(kind) || script == null) {
                error(exchange, 404);
                return;
            }
            for (String name : new String[]{"Range", "Cache-Control"}) {
                String value = exchange.getRequestHeaders().getFirst(name);
                if (value != null) params.put(name.toLowerCase(Locale.ROOT), value);
            }
            call = new ProxyCall(script, params);
            pending = workers.submit(call);
            PyProxyResponse response = pending.get(30, TimeUnit.SECONDS);
            if (loader.registeredScript(token, siteKey) != script) {
                error(exchange, 404);
                return;
            }
            Set<String> forbidden = new HashSet<>(HOP_HEADERS);
            response.headers.forEach((key, value) -> {
                if (key.equalsIgnoreCase("Connection")) {
                    Arrays.stream(value.split(",")).map(String::trim)
                            .map(s -> s.toLowerCase(Locale.ROOT)).forEach(forbidden::add);
                }
            });
            response.headers.forEach((key, value) -> {
                String lower = key.toLowerCase(Locale.ROOT);
                if (!forbidden.contains(lower) && !lower.equals("content-length") && !lower.equals("content-type")) {
                    exchange.getResponseHeaders().set(key, value);
                }
            });
            exchange.getResponseHeaders().set("Content-Type", response.mime);
            boolean noEntity = response.status == 204 || response.status == 304;
            if (!noEntity && response.contentLength >= 0) {
                exchange.getResponseHeaders().set("Content-Length", Long.toString(response.contentLength));
            }
            try (WriteDeadline deadline = new WriteDeadline()) {
                if (method.equals("HEAD") || noEntity || response.contentLength == 0) {
                    deadline.write(() -> exchange.sendResponseHeaders(response.status, -1));
                } else {
                    deadline.write(() -> exchange.sendResponseHeaders(response.status, Math.max(0, response.contentLength)));
                    byte[] chunk = new byte[65536];
                    int count;
                    while ((count = response.body.read(chunk)) != -1) {
                        int length = count;
                        deadline.write(() -> {
                            exchange.getResponseBody().write(chunk, 0, length);
                            exchange.getResponseBody().flush();
                        });
                    }
                    deadline.write(() -> exchange.getResponseBody().close());
                }
            }
        } catch (Exception error) {
            if (pending != null) pending.cancel(true);
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            // Script exceptions may contain URL tokens or headers. No raw exception is logged or returned here.
            if (exchange.getResponseCode() == -1) {
                error(exchange, loader.registeredScript(token, siteKey) == null ? 404 : 502);
            }
        } finally {
            if (call != null) call.close();
            exchange.close();
        }
    }

    private static final class ProxyCall implements Callable<PyProxyResponse>, AutoCloseable {
        private final PySpider script;
        private final Map<String, String> params;
        private PyProxyResponse response;
        private boolean abandoned;

        ProxyCall(PySpider script, Map<String, String> params) { this.script = script; this.params = params; }

        @Override
        public PyProxyResponse call() throws Exception {
            PyProxyResponse value = script.callProxy(params);
            synchronized (this) {
                if (!abandoned) { response = value; return value; }
            }
            value.close();
            throw new IOException("script proxy cancelled");
        }

        @Override
        public void close() throws IOException {
            PyProxyResponse owned;
            synchronized (this) { abandoned = true; owned = response; response = null; }
            if (owned != null) owned.close();
        }
    }

    private static final class WriteDeadline implements AutoCloseable {
        private static final ScheduledExecutorService TIMER = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "script-proxy-write-watchdog");
            thread.setDaemon(true);
            return thread;
        });
        private final Thread writer = Thread.currentThread();
        private final long timeoutMs = Math.max(1L, Math.min(30_000L, Long.getLong("xiugou.py.streamIdleTimeoutMs", 30_000L)));
        private final ScheduledFuture<?> timer;
        private long started;
        private boolean expired;
        private boolean closed;

        WriteDeadline() {
            long interval = Math.max(1L, Math.min(250L, timeoutMs / 4));
            timer = TIMER.scheduleWithFixedDelay(this::check, interval, interval, TimeUnit.MILLISECONDS);
        }

        private synchronized void check() {
            if (!closed && !expired && started != 0 && System.nanoTime() - started >= TimeUnit.MILLISECONDS.toNanos(timeoutMs)) {
                expired = true;
                // Interrupt closes HttpServer's blocked SocketChannel write. The lifetime lock
                // prevents a late timer from interrupting this executor thread's next request.
                writer.interrupt();
            }
        }

        void write(IoAction action) throws IOException {
            synchronized (this) {
                if (expired) throw new IOException("script proxy client stalled");
                started = System.nanoTime();
            }
            try { action.run(); }
            finally { synchronized (this) { started = 0; } }
        }

        @Override
        public synchronized void close() {
            closed = true;
            timer.cancel(false);
            if (expired) Thread.interrupted();
        }
    }

    private interface IoAction { void run() throws IOException; }

    private static Map<String, String> query(String raw) {
        Map<String, String> params = new HashMap<>();
        if (raw == null || raw.isEmpty()) return params;
        for (String part : raw.split("&")) {
            String[] pair = part.split("=", 2);
            String key = URLDecoder.decode(pair[0], StandardCharsets.UTF_8);
            String value = pair.length == 1 ? "" : URLDecoder.decode(pair[1], StandardCharsets.UTF_8);
            if (params.putIfAbsent(key, value) != null) throw new IllegalArgumentException("duplicate parameter");
        }
        return params;
    }

    private static void error(HttpExchange exchange, int status) throws IOException {
        String message = status == 404 ? "script proxy not registered" : status == 405 ? "method not allowed" : "script proxy failed";
        byte[] bytes = message.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
        exchange.getResponseHeaders().set("Content-Length", Integer.toString(bytes.length));
        if (exchange.getRequestMethod().equals("HEAD")) exchange.sendResponseHeaders(status, -1);
        else {
            exchange.sendResponseHeaders(status, bytes.length);
            exchange.getResponseBody().write(bytes);
        }
    }
}
