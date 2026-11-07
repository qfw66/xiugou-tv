package com.fongmi.companion;

import com.fongmi.companion.py.PySpider;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import java.io.IOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/** Lookup-only live event transport; no request can supply a script to load. */
final class ScriptDanmakuHandler implements HttpHandler {
    private final DexSpiderLoader loader;
    private final ScriptDanmakuRegistry registry;
    private final ExecutorService calls;
    private final String base;

    ScriptDanmakuHandler(DexSpiderLoader loader, ScriptDanmakuRegistry registry,
                         ExecutorService calls, String base) {
        this.loader = loader;
        this.registry = registry;
        this.calls = calls;
        this.base = base;
    }

    @Override public void handle(HttpExchange exchange) throws IOException {
        try {
            String path = exchange.getRequestURI().getRawPath();
            if (!path.equals("/script-danmaku/start") && !path.equals("/script-danmaku/events")
                    && !path.equals("/script-danmaku/stop")) {
                reply(exchange, 404, Map.of("error", "not found"));
                return;
            }
            boolean events = path.endsWith("/events");
            if (!(events ? "GET" : "POST").equals(exchange.getRequestMethod())) {
                reply(exchange, 405, Map.of("error", "method not allowed"));
                return;
            }
            Map<String, String> query = query(exchange.getRequestURI().getRawQuery());
            if (!events && exchange.getRequestBody().read() != -1) throw new IllegalArgumentException();
            if (path.endsWith("/start")) {
                start(exchange, query);
                return;
            }
            String id = query.getOrDefault("subscriptionId", "");
            String generation = query.getOrDefault("generation", "");
            if (!id.matches("[0-9a-f]{32}") || !generation.matches("[0-9a-f]{32}"))
                throw new IllegalArgumentException();
            if (!events) {
                registry.stop(id, generation);
                reply(exchange, 200, Map.of("closed", true));
                return;
            }
            ScriptDanmakuRegistry.Entry entry = registry.find(id, generation);
            if (entry == null) {
                reply(exchange, 404, Map.of("error", "not found"));
                return;
            }
            long after = Long.parseLong(query.getOrDefault("after", "0"));
            long wait = Math.max(0L, Math.min(20_000L, Long.parseLong(query.getOrDefault("wait", "20000"))));
            Map<String, Object> result = entry.poll(after, wait);
            reply(exchange, result == null ? 404 : 200, result == null ? Map.of("error", "not found") : result);
        } catch (IllegalArgumentException error) {
            if (exchange.getResponseCode() == -1) reply(exchange, 400, Map.of("error", "invalid request"));
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            if (exchange.getResponseCode() == -1) reply(exchange, 503, Map.of("error", "interrupted"));
        } catch (Exception error) {
            if (exchange.getResponseCode() == -1) reply(exchange, 502, Map.of("error", "script danmaku failed"));
        } finally {
            exchange.close();
        }
    }

    private void start(HttpExchange exchange, Map<String, String> query) throws Exception {
        PySpider spider = "py".equals(query.get("do"))
                ? loader.registeredScript(query.get("token"), query.get("siteKey")) : null;
        if (spider == null) {
            reply(exchange, 404, Map.of("error", "not found"));
            return;
        }
        String room = query.get("id");
        if (room == null || room.isEmpty() || room.getBytes(StandardCharsets.UTF_8).length > 4096)
            throw new IllegalArgumentException();
        StartCall call = new StartCall(spider, room);
        Future<ScriptDanmakuRegistry.Entry> pending = null;
        boolean delivered = false;
        try {
            pending = calls.submit(call);
            ScriptDanmakuRegistry.Entry entry = pending.get(30, TimeUnit.SECONDS);
            reply(exchange, 200, entry.started(base));
            delivered = true;
        } finally {
            if (!delivered) {
                call.abandon();
                if (pending != null) pending.cancel(true);
            }
        }
    }

    private final class StartCall implements Callable<ScriptDanmakuRegistry.Entry> {
        private final PySpider spider;
        private final String room;
        private ScriptDanmakuRegistry.Entry result;
        private boolean abandoned;

        StartCall(PySpider spider, String room) { this.spider = spider; this.room = room; }

        @Override public ScriptDanmakuRegistry.Entry call() throws Exception {
            ScriptDanmakuRegistry.Entry entry = registry.start(spider, room);
            boolean cancelled;
            synchronized (this) { result = entry; cancelled = abandoned; }
            if (cancelled) registry.stop(entry.id, entry.generation());
            return entry;
        }

        void abandon() {
            ScriptDanmakuRegistry.Entry entry;
            synchronized (this) { abandoned = true; entry = result; }
            if (entry != null) registry.stop(entry.id, entry.generation());
        }
    }

    private static Map<String, String> query(String raw) {
        Map<String, String> result = new LinkedHashMap<>();
        if (raw == null) return result;
        if (raw.length() > 16_384) throw new IllegalArgumentException();
        for (String part : raw.split("&")) {
            String[] pair = part.split("=", 2);
            String key = URLDecoder.decode(pair[0], StandardCharsets.UTF_8);
            String value = URLDecoder.decode(pair.length == 2 ? pair[1] : "", StandardCharsets.UTF_8);
            if (result.putIfAbsent(key, value) != null || value.chars().anyMatch(c -> c < 32 || c == 127))
                throw new IllegalArgumentException();
        }
        return result;
    }

    private static void reply(HttpExchange exchange, int status, Map<String, ?> result) throws IOException {
        byte[] bytes = JsonCodec.stringify(result).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(status, bytes.length);
        exchange.getResponseBody().write(bytes);
        exchange.getResponseBody().close();
    }
}
