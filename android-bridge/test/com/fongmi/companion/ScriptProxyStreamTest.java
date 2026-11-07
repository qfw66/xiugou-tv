package com.fongmi.companion;

import com.fongmi.companion.py.PySpider;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Stream;

/** Real loopback HTTP, runner and RuntimeReader; no public upstream or author code. */
public final class ScriptProxyStreamTest {
    private static final HttpClient HTTP = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3))
            .followRedirects(HttpClient.Redirect.NEVER).build();
    private static final byte[] CHUNK = new byte[65536];
    private static final String SCRIPT = """
            import json, os
            from urllib.parse import urlencode
            from base.net import RuntimeNet, RuntimeReader
            class Spider:
                def init(self, ext=''):
                    config = json.loads(ext)
                    self.origin, self.marker = config['origin'], config['marker']
                    self._net = RuntimeNet()
                    self.items, self.closed, self.reads = [], set(), 0
                    original_close, original_read = RuntimeReader.close, RuntimeReader.read
                    owner = self
                    def close(reader):
                        try: return original_close(reader)
                        finally:
                            if reader in owner.items and id(reader) not in owner.closed:
                                owner.closed.add(id(reader))
                                with open(owner.marker + '.closed', 'a') as out: out.write('close\\n')
                    RuntimeReader.close = close
                    def read(reader, size=65536):
                        owner.reads += 1
                        with open(owner.marker + '.read', 'w') as out: out.write(str(os.getpid()))
                        return original_read(reader, size)
                    RuntimeReader.read = read
                def liveContent(self, url=''):
                    return {'url': os.environ['XIUGOU_SCRIPT_PROXY_BASE'] + '&' + urlencode({
                        'do': 'py', 'siteKey': os.environ['XIUGOU_SCRIPT_SITE_KEY']}), 'pid': os.getpid()}
                def proxy(self, params):
                    kind = params.get('kind', 'small')
                    if kind == 'echo': return [200, 'application/json', json.dumps(params)]
                    result = self._net.stream(self.origin + '/' + kind, {'timeout': 8000, 'callTimeout': 10000,
                        'headers': {k: v for k, v in params.items() if k in ('range', 'cache-control')}})
                    reader = result['stream']
                    self.items.append(reader)
                    headers = dict(result['headers'])
                    headers.update({'Connection': 'X-Hop', 'X-Hop': 'removed'})
                    return [result['code'], result['contentType'], reader, headers]
                def action(self, value=''):
                    return {'pid': os.getpid(), 'opened': len(self.items), 'active': len(self.items)-len(self.closed),
                            'closed': len(self.closed), 'reads': self.reads}
            """;
    private final Path root = Files.createTempDirectory("xiugou-proxy-stream-").toRealPath();
    private final String previousHome = System.getProperty("user.home");
    private final ExecutorService upstreamWorkers = Executors.newCachedThreadPool();
    private final CountDownLatch releaseStalls = new CountDownLatch(1);
    private final CountDownLatch releaseSibling = new CountDownLatch(1);
    private final AtomicReference<Map<String, List<String>>> upstreamHeaders = new AtomicReference<>();
    private final HttpServer upstream;
    private final SpiderServer bridge;
    private final String origin;
    private final String upstreamOrigin;
    private final Path script;
    private final List<String> failures = new ArrayList<>();

    private ScriptProxyStreamTest() throws Exception {
        for (int i = 0; i < CHUNK.length; i++) CHUNK[i] = new byte[]{0, (byte)128, (byte)255}[i % 3];
        System.setProperty("user.home", Files.createDirectories(root.resolve("home")).toString());
        System.setProperty("xiugou.py.maxProcesses", "1");
        System.setProperty("xiugou.py.streamReadTimeoutMs", "800");
        System.setProperty("xiugou.py.streamIdleTimeoutMs", "1000");
        script = root.resolve("stream.py");
        Files.writeString(script, SCRIPT, StandardCharsets.UTF_8);
        upstream = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        upstream.setExecutor(upstreamWorkers);
        upstream.createContext("/", this::serve);
        upstream.start();
        upstreamOrigin = "http://127.0.0.1:" + upstream.getAddress().getPort();
        bridge = new SpiderServer(0);
        origin = "http://127.0.0.1:" + bridge.start();
    }

    public static void main(String[] args) throws Exception {
        ScriptProxyStreamTest test = new ScriptProxyStreamTest();
        try {
            test.run("subpaths and lower-case request header overrides", test::addresses);
            test.run("large binary, 206/416 headers and bounded chunks", test::large);
            test.run("HEAD closes without reading", test::head);
            test.run("active stream pins child and original-runtime ownership", test::pin);
            test.run("client disconnect releases reader", () -> test.socketClient(true));
            test.run("slow client watchdog releases reader", () -> test.socketClient(false));
            test.run("continuous progress outlives idle deadline", test::progress);
            test.run("stalled SDK read cancels target and preserves child", test::timeout);
            test.run("interrupt cancels target and preserves child", test::interrupt);
            test.run("reset revokes active stream and token", test::reset);
            test.run("closing one handle preserves another in-flight chunk", test::sibling);
            test.run("destroy invalidates already buffered bytes", test::buffered);
            check(test.failures.isEmpty(), String.join("\n", test.failures));
            System.out.println("ScriptProxyStreamTest OK (12 real HTTP/process stream boundaries)");
        } finally {
            test.bridge.stop();
            test.releaseStalls.countDown();
            test.upstream.stop(0);
            test.upstreamWorkers.shutdownNow();
            test.upstreamWorkers.awaitTermination(3, TimeUnit.SECONDS);
            if (test.previousHome == null) System.clearProperty("user.home");
            else System.setProperty("user.home", test.previousHome);
            check(test.root.isAbsolute() && test.root.getFileName().toString().startsWith("xiugou-proxy-stream-"), "verify generated cleanup root");
            try (Stream<Path> files = Files.walk(test.root)) {
                for (Path path : (Iterable<Path>) files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
            }
        }
    }

    private void serve(HttpExchange exchange) throws java.io.IOException {
        upstreamHeaders.set(new LinkedHashMap<>(exchange.getRequestHeaders()));
        String kind = exchange.getRequestURI().getPath().substring(1);
        int status = kind.equals("failure") ? 416 : 206;
        int chunks = kind.equals("huge") ? 97 : kind.equals("endless") ? 4096 : kind.equals("slow") ? 24 : 0;
        long length = chunks == 0 ? 3 : (long) chunks * CHUNK.length;
        exchange.getResponseHeaders().set("Content-Type", "application/octet-stream");
        exchange.getResponseHeaders().set("Content-Range", "bytes 0-" + (length - 1) + "/" + length);
        exchange.getResponseHeaders().set("Accept-Ranges", "bytes");
        exchange.sendResponseHeaders(status, length);
        try {
            if (kind.equals("stall")) releaseStalls.await(8, TimeUnit.SECONDS);
            if (kind.equals("sibling")) releaseSibling.await(3, TimeUnit.SECONDS);
            if (chunks == 0) exchange.getResponseBody().write(new byte[]{0, (byte)128, (byte)255});
            for (int i = 0; i < chunks; i++) {
                exchange.getResponseBody().write(CHUNK);
                exchange.getResponseBody().flush();
                if (kind.equals("slow")) Thread.sleep(80);
            }
        } catch (java.io.IOException expectedDisconnect) {
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        } finally { exchange.close(); }
    }

    private Map<String, Object> descriptor(String site) {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("key", site); value.put("siteKey", site); value.put("api", script.toString());
        value.put("ext", JsonCodec.stringify(Map.of("origin", upstreamOrigin, "marker", root.resolve(site).toString())));
        value.put("timeoutMs", 5000); return value;
    }
    private String load(String site) throws Exception {
        check(request("POST", origin + "/spider/load", JsonCodec.stringify(descriptor(site))).statusCode() == 200, "load succeeds");
        return (String) call(site, "liveContent").get("url");
    }
    private Map<String, Object> call(String site, String method) throws Exception {
        Map<String, Object> data = descriptor(site); data.put("method", method);
        HttpResponse<byte[]> response = request("POST", origin + "/spider/call", JsonCodec.stringify(data));
        check(response.statusCode() == 200, "call must succeed: " + response.statusCode());
        Object value = JsonCodec.parseObject(new String(response.body(), StandardCharsets.UTF_8)).get("data");
        check(value instanceof Map, "call returns structured result");
        @SuppressWarnings("unchecked") Map<String, Object> result = (Map<String, Object>) value;
        return result;
    }
    private PySpider direct(String site) {
        PySpider spider = new PySpider(script.toString(), (String) descriptor(site).get("ext"), root.toFile(), site, origin + "/script-proxy");
        spider.init(null, ""); return spider;
    }
    private static long pid(PySpider spider) throws Exception { return ((Number) JsonCodec.parseObject(spider.action("")).get("pid")).longValue(); }
    private static InputStream stream(PySpider spider, String kind) { return (InputStream) spider.proxy(Map.of("kind", kind))[2]; }
    private void idle(String site) throws Exception {
        await(() -> ((Number) call(site, "action").get("active")).intValue() == 0, "reader count must return to zero");
    }

    private void addresses() throws Exception {
        String base = load("addresses");
        String subpath = base.replace("/script-proxy?", "/script-proxy/segment/1.ts?");
        HttpResponse<byte[]> response = HTTP.send(HttpRequest.newBuilder(URI.create(subpath + "&kind=echo&range=wrong&cache-control=wrong"))
                .header("Range", "bytes=9-12").header("Cache-Control", "no-cache").GET().build(), HttpResponse.BodyHandlers.ofByteArray());
        check(response.statusCode() == 200, "slash subpath must route to same registration");
        Map<String, Object> params = JsonCodec.parseObject(new String(response.body(), StandardCharsets.UTF_8));
        check(params.equals(Map.of("kind", "echo", "range", "bytes=9-12", "cache-control", "no-cache")), "headers override only lower-case payload keys");
        check(request("GET", base.replace("/script-proxy?", "/script-proxyX?"), null).statusCode() == 404, "prefix lookalike must not route");
    }
    private void large() throws Exception {
        String url = load("large");
        HttpResponse<byte[]> response = HTTP.send(HttpRequest.newBuilder(URI.create(url + "&kind=huge"))
                .timeout(Duration.ofSeconds(8)).header("Range", "bytes=0-").GET().build(), HttpResponse.BodyHandlers.ofByteArray());
        check(response.statusCode() == 206 && response.body().length == 97 * CHUNK.length, "stream exceeds old 4MiB cap");
        for (int i = 0; i < response.body().length; i++) check(response.body()[i] == CHUNK[i % CHUNK.length], "00/80/ff bytes survive");
        check(response.headers().firstValue("Content-Range").isPresent() && response.headers().firstValue("Accept-Ranges").orElse("").equals("bytes"), "range metadata survives");
        check(response.headers().firstValue("X-Hop").isEmpty(), "connection nominated header stripped");
        check(upstreamHeaders.get().entrySet().stream().anyMatch(e -> e.getKey().equalsIgnoreCase("range") && e.getValue().contains("bytes=0-")), "Range reaches upstream");
        HttpResponse<byte[]> failure = request("GET", url + "&kind=failure", null);
        check(failure.statusCode() == 416 && Arrays.equals(failure.body(), new byte[]{0, (byte)128, (byte)255}), "error status body preserved");
        idle("large");
    }
    private void head() throws Exception {
        String url = load("head");
        HttpResponse<byte[]> response = request("HEAD", url + "&kind=huge", null);
        check(response.statusCode() == 206 && response.body().length == 0, "HEAD only metadata");
        idle("head");
        check(((Number) call("head", "action").get("reads")).intValue() == 0, "HEAD must not read any chunk");
    }
    private void pin() throws Exception {
        PySpider first = direct("pinned"); PySpider other = null;
        try (InputStream input = stream(first, "huge")) {
            long original = pid(first);
            other = direct("pressure");
            Thread.sleep(150);
            check(pid(first) == original, "busy child cannot be evicted by another registration");
            check(input.read() == 0, "original handle remains readable");
        } finally { first.destroy(); if (other != null) other.destroy(); }
    }
    private void socketClient(boolean disconnect) throws Exception {
        String site = disconnect ? "disconnect" : "slowclient";
        URI uri = URI.create(load(site) + "&kind=endless");
        try (Socket socket = new Socket()) {
            socket.setReceiveBufferSize(1024); socket.setSoTimeout(3000);
            socket.connect(new InetSocketAddress(uri.getHost(), uri.getPort()));
            socket.getOutputStream().write(("GET " + uri.getRawPath() + "?" + uri.getRawQuery() + " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().flush();
            if (disconnect) {
                check(socket.getInputStream().read() >= 0, "HTTP stream must start");
                socket.setSoLinger(true, 0); socket.close();
            }
            await(() -> Files.exists(root.resolve(site + ".closed")), "client abandonment must close reader without next RPC");
        }
        idle(site);
    }
    private void progress() throws Exception {
        String url = load("progress");
        long start = System.nanoTime();
        HttpResponse<byte[]> response = request("GET", url + "&kind=slow", null);
        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) > 1000, "fixture must outlive configured idle deadline");
        check(response.statusCode() == 206 && response.body().length == 24 * CHUNK.length, "progress must extend inactivity deadline");
        idle("progress");
    }
    private void timeout() throws Exception {
        PySpider spider = direct("timeout");
        try {
            long original = pid(spider);
            try (InputStream input = stream(spider, "stall")) {
                long start = System.nanoTime();
                try { input.read(); throw new AssertionError("stalled read must fail"); }
                catch (java.io.IOException expected) { }
                check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 3000, "Java chunk timeout must bound stuck read");
                check(pid(spider) == original, "SDK timeout must preserve original child");
                check(((Number) JsonCodec.parseObject(spider.action("")).get("active")).intValue() == 0,
                        "SDK timeout must release its reader");
                input.close();
                check(pid(spider) == original, "repeated close remains harmless");
            }
        } finally { spider.destroy(); }
    }
    private void interrupt() throws Exception {
        PySpider spider = direct("interrupt");
        try (InputStream input = stream(spider, "stall")) {
            long original = pid(spider);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            Thread worker = new Thread(() -> { try { input.read(); } catch (Throwable error) { failure.set(error); } });
            worker.start();
            await(() -> Files.exists(root.resolve("interrupt.read")), "chunk read must be in progress");
            worker.interrupt(); worker.join(2000);
            check(!worker.isAlive() && failure.get() instanceof java.io.IOException, "interruption must release read thread");
            check(pid(spider) == original, "interrupted SDK read must preserve original child");
            check(((Number) JsonCodec.parseObject(spider.action("")).get("active")).intValue() == 0,
                    "interrupted SDK read must release its reader");
        } finally { spider.destroy(); }
    }
    private void reset() throws Exception {
        String url = load("reset");
        long child = ((Number) call("reset", "action").get("pid")).longValue();
        HttpResponse<InputStream> response = HTTP.send(HttpRequest.newBuilder(URI.create(url + "&kind=stall")).GET().build(), HttpResponse.BodyHandlers.ofInputStream());
        try (InputStream input = response.body()) {
            check(response.statusCode() == 206, "stream must open before reset");
            await(() -> Files.exists(root.resolve("reset.read")), "native read must start");
            check(request("POST", origin + "/spider/reset", "{}").statusCode() == 200, "reset succeeds");
            await(() -> !ProcessHandle.of(child).map(ProcessHandle::isAlive).orElse(false), "reset kills original child");
            check(request("GET", url, null).statusCode() == 404, "reset revokes old address");
            check(!load("reset").equals(url), "same descriptor has a new token after reset");
        }
    }

    private void sibling() throws Exception {
        PySpider spider = direct("sibling");
        try (InputStream active = stream(spider, "sibling"); InputStream idle = stream(spider, "small")) {
            long original = pid(spider);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            AtomicReference<Integer> value = new AtomicReference<>();
            Thread worker = new Thread(() -> { try { value.set(active.read()); } catch (Throwable error) { failure.set(error); } });
            worker.start();
            await(() -> Files.exists(root.resolve("sibling.read")), "sibling read must be in flight");
            Thread release = new Thread(() -> {
                try { Thread.sleep(150); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
                finally { releaseSibling.countDown(); }
            });
            release.start();
            idle.close();
            worker.join(2000); release.join(1000);
            check(!worker.isAlive() && failure.get() == null && Integer.valueOf(0).equals(value.get()), "closing idle handle must preserve sibling read");
            check(pid(spider) == original, "sibling close must not restart process");
        } finally { releaseSibling.countDown(); spider.destroy(); }
    }
    private void buffered() throws Exception {
        PySpider spider = direct("buffered");
        try (InputStream input = stream(spider, "huge")) {
            check(input.read() == 0, "stream fills its bounded local chunk");
            spider.destroy();
            try { input.read(); throw new AssertionError("retired child must invalidate cached stream bytes"); }
            catch (java.io.IOException expected) { }
        } finally { spider.destroy(); }
    }

    private void run(String name, CheckedCase action) {
        try { action.run(); System.out.println("PASS " + name); }
        catch (Exception | AssertionError error) { failures.add(name + ": " + error); System.out.println("FAIL " + name + ": " + error); }
    }
    private static HttpResponse<byte[]> request(String method, String url, String body) throws Exception {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(8))
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body)).build(), HttpResponse.BodyHandlers.ofByteArray());
    }
    private static void await(CheckedCondition predicate, String message) throws Exception {
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (!predicate.get() && System.nanoTime() < until) Thread.sleep(20);
        check(predicate.get(), message);
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private interface CheckedCase { void run() throws Exception; }
    private interface CheckedCondition { boolean get() throws Exception; }
}
