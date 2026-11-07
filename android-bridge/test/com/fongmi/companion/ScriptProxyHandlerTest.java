package com.fongmi.companion;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import java.util.stream.Stream;

/** Real loopback RPC/HTTP + Python children, with synthetic scripts and an isolated home. */
public final class ScriptProxyHandlerTest {
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(3)).followRedirects(HttpClient.Redirect.NEVER).build();
    private static final String SCRIPT = """
            import os, time
            from urllib.parse import urlencode
            class Spider:
                def init(self, ext=''):
                    self.ext = ext
                    if ext.startswith('restart-wait:'):
                        marker = ext[len('restart-wait:'):]
                        if os.path.exists(marker):
                            with open(marker + '.pid', 'w') as out: out.write(str(os.getpid()))
                            time.sleep(12)
                        else:
                            with open(marker, 'w') as out: out.write('loaded')
                def liveContent(self, url=''):
                    base = os.environ.get('XIUGOU_SCRIPT_PROXY_BASE', '')
                    query = urlencode({'do': 'py', 'siteKey': os.environ.get('XIUGOU_SCRIPT_SITE_KEY', '')})
                    return {'url': base + '&' + query, 'pid': os.getpid(),
                            'api': os.environ.get('XIUGOU_SCRIPT_API'), 'base': os.environ.get('XIUGOU_SCRIPT_BASE')}
                def action(self, value):
                    if value.startswith('sleep:'):
                        with open(value[6:], 'w') as out: out.write(str(os.getpid()))
                        time.sleep(30)
                    return {'pid': os.getpid()}
                def proxy(self, params):
                    kind = params.get('kind', 'text')
                    if kind == 'binary': return [206, 'application/octet-stream', bytes([0,128,255]),
                        {'X-Source': self.ext, 'Connection': 'X-Hop', 'X-Hop': 'must-strip',
                         'Transfer-Encoding': 'chunked', 'Content-Length': '999'}]
                    if kind == 'redirect': return [302, 'text/plain', '', {'Location': 'https://media.invalid/a?token=synthetic'}]
                    if kind == 'invalid': raise ValueError('secret-canary URL https://private.invalid/token')
                    if kind == 'oversize': return [200, 'text/plain', b'x' * (4*1024*1024+1)]
                    return [200, 'application/json; charset=utf-8', '{"节目":"新闻"}', {'X-Source': self.ext}]
            """;

    private final List<String> failures = new ArrayList<>();
    private final Path root;
    private final Path script;
    private final SpiderServer server;
    private final String origin;

    private ScriptProxyHandlerTest() throws Exception {
        root = Files.createTempDirectory("xiugou-script-proxy-test-").toRealPath();
        System.setProperty("user.home", Files.createDirectories(root.resolve("home")).toString());
        System.setProperty("xiugou.py.maxProcesses", "1");
        script = root.resolve("source.py");
        Files.writeString(script, SCRIPT, StandardCharsets.UTF_8);
        server = new SpiderServer(0);
        origin = "http://127.0.0.1:" + server.start();
    }

    public static void main(String[] args) throws Exception {
        ScriptProxyHandlerTest test = new ScriptProxyHandlerTest();
        try {
            test.run("unknown registration cannot launch api", test::unknown);
            test.run("status bytes headers HEAD and bounded failure", test::responses);
            test.run("same site different ext stays isolated", test::descriptors);
            test.run("file URI and original source environment", test::fileUri);
            test.run("idle eviction preserves URL and restarts child", test::idleRestart);
            test.run("reset revokes old token even after reload", test::reset);
            test.run("watchdog interrupts Python and allows restart", test::timeout);
            test.run("explicit RPC cancellation interrupts Python", test::cancel);
            test.run("reset interrupts a proxy-triggered idle restart", test::resetDuringRestart);
            if (!test.failures.isEmpty()) throw new AssertionError(String.join("\n", test.failures));
            System.out.println("ScriptProxyHandlerTest OK (9 real HTTP/process boundaries)");
        } finally {
            test.server.stop();
            check(test.root.isAbsolute() && test.root.getFileName().toString().startsWith("xiugou-script-proxy-test-"),
                    "cleanup must remain inside generated test root");
            try (Stream<Path> files = Files.walk(test.root)) {
                for (Path file : (Iterable<Path>) files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(file);
            }
        }
    }

    private void run(String name, CheckedCase test) {
        try {
            test.run();
            System.out.println("PASS " + name);
        } catch (Exception | AssertionError error) {
            failures.add(name + ": " + error.getMessage());
            System.out.println("FAIL " + name + ": " + error.getClass().getSimpleName());
        }
    }

    private void unknown() throws Exception {
        HttpResponse<byte[]> result = request("GET", origin + "/script-proxy?do=py&siteKey=never&api="
                + java.net.URLEncoder.encode(script.toString(), StandardCharsets.UTF_8), null);
        check(result.statusCode() == 404, "unregistered route must be 404");
        check(request("POST", origin + "/script-proxy", "{}").statusCode() == 405, "only GET and HEAD are accepted");
    }

    private Map<String, Object> descriptor(String site, String api, String ext) {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("siteKey", site); value.put("api", api); value.put("ext", ext);
        value.put("timeoutMs", 5000); return value;
    }

    private Map<String, Object> load(String site, String api, String ext) throws Exception {
        Map<String, Object> value = descriptor(site, api, ext);
        value.put("key", site);
        check(request("POST", origin + "/spider/load", JsonCodec.stringify(value)).statusCode() == 200, "load RPC must succeed");
        return call(value, "liveContent", "");
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> call(Map<String, Object> value, String method, String action) throws Exception {
        Map<String, Object> payload = new LinkedHashMap<>(value);
        payload.put("method", method); payload.put("action", action);
        HttpResponse<byte[]> response = request("POST", origin + "/spider/call", JsonCodec.stringify(payload));
        check(response.statusCode() == 200, "call RPC must succeed: status=" + response.statusCode());
        Object data = JsonCodec.parseObject(text(response)).get("data");
        check(data instanceof Map, "RPC must return structured source data");
        return (Map<String, Object>) data;
    }

    private String proxyUrl(Map<String, Object> source) {
        String url = String.valueOf(source.get("url"));
        check(url.startsWith(origin + "/script-proxy?token="), "source must receive a registered URL on the RPC port");
        return url;
    }

    private void responses() throws Exception {
        String url = proxyUrl(load("responses", script.toString(), "A"));
        HttpResponse<byte[]> text = request("GET", url, null);
        check(text.statusCode() == 200 && text(text).equals("{\"节目\":\"新闻\"}"), "UTF-8 JSON must remain intact");
        HttpResponse<byte[]> binary = request("GET", url + "&kind=binary", null);
        check(binary.statusCode() == 206 && java.util.Arrays.equals(binary.body(), new byte[]{0, (byte)128, (byte)255}), "binary bytes/status must remain intact");
        check(binary.headers().firstValue("X-Source").orElse("").equals("A"), "end-to-end header must survive");
        check(binary.headers().firstValue("X-Hop").isEmpty() && binary.headers().firstValue("Transfer-Encoding").isEmpty(), "hop-by-hop headers must be stripped");
        check(binary.headers().firstValue("Content-Length").orElse("").equals("3"), "host must frame actual byte length");
        HttpResponse<byte[]> head = request("HEAD", url + "&kind=binary", null);
        check(head.statusCode() == 206 && head.body().length == 0 && head.headers().firstValue("Content-Length").orElse("").equals("3"), "HEAD must preserve metadata without a body");
        HttpResponse<byte[]> redirect = request("GET", url + "&kind=redirect", null);
        check(redirect.statusCode() == 302 && redirect.headers().firstValue("Location").orElse("").equals("https://media.invalid/a?token=synthetic"), "302 Location must not be followed or rewritten");
        for (String kind : List.of("invalid", "oversize")) {
            HttpResponse<byte[]> failure = request("GET", url + "&kind=" + kind, null);
            check(failure.statusCode() == 502 && !text(failure).contains("secret-canary") && !text(failure).contains("private.invalid"), "proxy errors must be bounded, safe 502 responses");
        }
    }

    private void descriptors() throws Exception {
        String first = proxyUrl(load("same-site", script.toString(), "A"));
        String second = proxyUrl(load("same-site", script.toString(), "B"));
        check(!first.equals(second), "different ext requires an isolated registration");
        check(request("GET", first, null).headers().firstValue("X-Source").orElse("").equals("A"), "old descriptor must remain bound to A");
        check(request("GET", second, null).headers().firstValue("X-Source").orElse("").equals("B"), "new descriptor must remain bound to B");
    }

    private void fileUri() throws Exception {
        String api = script.toUri().toString();
        Map<String, Object> source = load("file-uri", api, "file");
        proxyUrl(source);
        check(api.equals(source.get("api")), "original API must be injected, not the cache path");
        check(script.getParent().toUri().toString().equals(source.get("base")), "original directory URI must be injected");
    }

    private void idleRestart() throws Exception {
        Map<String, Object> first = load("idle-first", script.toString(), "A");
        String url = proxyUrl(first);
        long pid = ((Number) first.get("pid")).longValue();
        load("idle-other", script.toString(), "B");
        await(() -> ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false) == false, "idle child must be evicted");
        check(request("GET", url, null).statusCode() == 200, "registered URL must lazily restart an evicted child");
        Map<String, Object> restarted = call(descriptor("idle-first", script.toString(), "A"), "liveContent", "");
        check(((Number) restarted.get("pid")).longValue() != pid && proxyUrl(restarted).equals(url), "idle restart must keep URL but replace process");
    }

    private void reset() throws Exception {
        String old = proxyUrl(load("reset", script.toString(), "A"));
        check(request("POST", origin + "/spider/reset", "{}").statusCode() == 200, "reset succeeds");
        check(request("GET", old, null).statusCode() == 404, "reset must revoke old URL");
        String fresh = proxyUrl(load("reset", script.toString(), "A"));
        check(!fresh.equals(old) && request("GET", old, null).statusCode() == 404, "reload must not revive old token");
    }

    private void timeout() throws Exception {
        Path marker = root.resolve("timeout-started");
        Map<String, Object> value = descriptor("timeout", script.toString(), "");
        load("timeout", script.toString(), "");
        value.put("method", "action"); value.put("action", "sleep:" + marker); value.put("timeoutMs", 300);
        HttpResponse<byte[]> response = request("POST", origin + "/spider/call", JsonCodec.stringify(value));
        check(response.statusCode() == 504 && Files.exists(marker), "watchdog must time out a running Python call");
        long pid = Long.parseLong(Files.readString(marker));
        await(() -> !ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false), "watchdog must terminate child");
        check(((Number) call(descriptor("timeout", script.toString(), ""), "action", "ok").get("pid")).longValue() != pid, "timed-out channel must restart without stale replies");
    }

    private void cancel() throws Exception {
        Path marker = root.resolve("cancel-started");
        Map<String, Object> value = descriptor("cancel", script.toString(), "");
        load("cancel", script.toString(), "");
        value.put("method", "action"); value.put("action", "sleep:" + marker); value.put("rpcId", "synthetic-cancel");
        CompletableFuture<HttpResponse<byte[]>> pending = HTTP.sendAsync(HttpRequest.newBuilder(URI.create(origin + "/spider/call"))
                .timeout(Duration.ofSeconds(8)).POST(HttpRequest.BodyPublishers.ofString(JsonCodec.stringify(value))).build(), HttpResponse.BodyHandlers.ofByteArray());
        await(() -> Files.exists(marker), "Python call must reach its wait boundary");
        long pid = Long.parseLong(Files.readString(marker));
        request("POST", origin + "/spider/cancel", "{\"rpcId\":\"synthetic-cancel\"}");
        HttpResponse<byte[]> response = pending.get(2, TimeUnit.SECONDS);
        check(response.statusCode() >= 400, "cancelled RPC must finish as cancellation");
        await(() -> !ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false), "cancel must terminate child");
        check(((Number) call(descriptor("cancel", script.toString(), ""), "action", "ok").get("pid")).longValue() != pid, "cancelled child must restart on next call");
    }

    private void resetDuringRestart() throws Exception {
        Path marker = root.resolve("restart-wait");
        String ext = "restart-wait:" + marker;
        Map<String, Object> first = load("restart-reset", script.toString(), ext);
        String oldUrl = proxyUrl(first);
        long firstPid = ((Number) first.get("pid")).longValue();
        load("evict-restart-reset", script.toString(), "other");
        await(() -> !ProcessHandle.of(firstPid).map(ProcessHandle::isAlive).orElse(false), "first child must be evicted");
        CompletableFuture<HttpResponse<byte[]>> pending = HTTP.sendAsync(HttpRequest.newBuilder(URI.create(oldUrl))
                .timeout(Duration.ofSeconds(20)).GET().build(), HttpResponse.BodyHandlers.ofByteArray());
        try {
            Path started = Path.of(marker + ".pid");
            await(() -> Files.exists(started), "proxy-triggered init must start");
            long restartingPid = Long.parseLong(Files.readString(started));
            long beforeReset = System.nanoTime();
            check(request("POST", origin + "/spider/reset", "{}").statusCode() == 200, "reset must finish while init is pending");
            check(System.nanoTime() - beforeReset < TimeUnit.SECONDS.toNanos(2), "reset must not await old init");
            await(() -> !ProcessHandle.of(restartingPid).map(ProcessHandle::isAlive).orElse(false), "reset must terminate initializing child");
            check(pending.get(2, TimeUnit.SECONDS).statusCode() == 404, "retired proxy call must not publish a response");
            check(request("GET", oldUrl, null).statusCode() == 404, "retired URL remains revoked");
            check(request("GET", proxyUrl(load("after-restart-reset", script.toString(), "fresh")), null).statusCode() == 200,
                    "new descriptors must work after reset");
        } finally {
            pending.cancel(true);
        }
    }

    private static HttpResponse<byte[]> request(String method, String url, String body) throws Exception {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(8))
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body))
                .build(), HttpResponse.BodyHandlers.ofByteArray());
    }

    private static String text(HttpResponse<byte[]> response) { return new String(response.body(), StandardCharsets.UTF_8); }
    private static void await(BooleanSupplier condition, String message) throws Exception {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (!condition.getAsBoolean() && System.nanoTime() < end) Thread.sleep(20);
        check(condition.getAsBoolean(), message);
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private interface CheckedCase { void run() throws Exception; }
}
