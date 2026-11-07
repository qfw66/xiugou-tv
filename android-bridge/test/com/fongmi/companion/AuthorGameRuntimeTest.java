package com.fongmi.companion;

import com.fongmi.companion.py.PyProxyResponse;
import com.fongmi.companion.py.PySpider;
import java.io.IOException;
import java.lang.reflect.Field;
import java.net.URI;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;

/** Original game entry/helpers, real Java/Python/HTTP/WS; only upstream destinations are redirected. */
public final class AuthorGameRuntimeTest implements AutoCloseable {
    private static final String SITE = "original-game + 中文";
    private static final List<String> SOURCES = List.of("game_live.py", "game_live_protocol.py", "game_live_stream.py", "game_live_yy.py");
    private static final HttpClient HTTP = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3))
            .followRedirects(HttpClient.Redirect.NEVER).build();
    private static final int TAG_LENGTH = 90 * 1024 + 15;
    private final Path repo = Path.of("").toAbsolutePath().normalize();
    private final Path author;
    private final Path root;
    private final String previousHome = System.getProperty("user.home");
    private final List<Map<String,Object>> polls = new ArrayList<>();
    private Process fixture;
    private SpiderServer bridge;
    private String upstream, base, api;
    private long childPid, cancellationMillis;
    private Map<String,Object> ready, hashes;

    private AuthorGameRuntimeTest(Path author) throws IOException {
        this.author = author.toRealPath();
        root = Files.createTempDirectory("xiugou-author-game-").toRealPath();
    }

    public static void main(String[] args) throws Exception {
        String configured = System.getProperty("xiugou.author.game", System.getenv("XIUGOU_AUTHOR_GAME"));
        Path author = Path.of(configured == null || configured.isBlank()
                ? "E:/code/tvbox_1102/live-python/vod/game_live.py" : configured).toAbsolutePath().normalize();
        for (String name : SOURCES) {
            if (!Files.isRegularFile(author.resolveSibling(name))) {
                System.out.println("SKIP AuthorGameRuntimeTest: original source missing; set xiugou.author.game or XIUGOU_AUTHOR_GAME");
                return;
            }
        }
        AuthorGameRuntimeTest test = new AuthorGameRuntimeTest(author);
        try (test) {
            test.start();
            test.sources();
            test.vertical();
            test.checkHashes();
        }
        System.out.println("AuthorGameRuntimeTest OK (original init/search/two-CDN FLV/Huya danmaku/cancel/EOF/reset)");
        System.out.println("Artifacts: " + test.root);
    }

    private void start() throws Exception {
        hashes = sourceHashes();
        String python = System.getProperty("xiugou.python", repo.resolve("companion/pyruntime/python.exe").toString());
        Path fixtureSource = repo.resolve("companion/pyshell/tests/author_game_fixture.py");
        fixture = new ProcessBuilder(python, "-B", fixtureSource.toString(), "--root", root.toString(), "--author", author.toString())
                .redirectOutput(root.resolve("upstream.stdout.log").toFile())
                .redirectError(root.resolve("upstream.stderr.log").toFile()).start();
        await(() -> Files.isRegularFile(root.resolve("ready.json")) || !fixture.isAlive(), 5000, "fixture startup");
        check(fixture.isAlive(), "upstream fixture failed; inspect " + root);
        ready = JsonCodec.parseObject(Files.readString(root.resolve("ready.json")));
        upstream = string(ready.get("origin"));
        check(hashes.equals(ready.get("hashes")), "fixture loads the same four original source bytes");
        System.setProperty("user.home", Files.createDirectories(root.resolve("home")).toString());
        bridge = new SpiderServer(0);
        base = "http://127.0.0.1:" + bridge.start();
    }

    private void sources() throws Exception {
        check(repo.getRoot().equals(author.getRoot()), "relative local source regression needs author on the repository drive");
        api = repo.relativize(author).toString().replace('\\', '/');
        check(!Path.of(api).isAbsolute(), "local origin must exercise a genuinely relative API");
        smoke();
        reset();
        api = upstream + "/ordinary/game_live.py";
        smoke();
        Map<String,Object> status = status();
        for (String helper : SOURCES.subList(1, SOURCES.size()))
            check(hasRequest(status, "/ordinary/" + helper), "ordinary HTTP entry must fetch original " + helper);
        reset();
        api = upstream + "/https://github.com/fixture/game/blob/main/vod/game_live.py";
        smoke();
        status = status();
        for (String source : SOURCES)
            check(hasRequest(status, "/https://raw.githubusercontent.com/fixture/game/main/vod/" + source),
                    "proxy prefix and raw effective path must survive host/helper resolution: " + source);
        List<Map<String,Object>> loaded = observations("loaded");
        check(loaded.size() == 1, "proxy entry should create one original author instance");
        Map<String,Object> record = loaded.get(0);
        childPid = number(record.get("pid"));
        Map<?,?> environment = object(record.get("environment"));
        check(api.equals(environment.get("XIUGOU_SCRIPT_API")), "original API must remain the storage identity");
        check((upstream + "/https://raw.githubusercontent.com/fixture/game/main/vod/game_live.py")
                .equals(environment.get("XIUGOU_SCRIPT_ENTRY")), "effective ENTRY must be original raw source, not download cache");
        check(SITE.equals(environment.get("XIUGOU_SCRIPT_SITE_KEY")), "site identity must reach original init");
        check(ProcessHandle.of(childPid).map(ProcessHandle::isAlive).orElse(false), "recorded original child must be alive");
        System.out.println("PASS actual original init/search via relative local, HTTP, and proxied GitHub effective sources");
    }

    private void smoke() throws Exception {
        rpc("/spider/load", descriptor());
        Map<String,Object> home = call("homeContent", Map.of("filter", "false"));
        check(list(home.get("class")).size() == 3, "original home platform classes");
        Map<String,Object> search = call("searchContent", Map.of("wd", "主播 中文", "pg", "1"));
        check(list(search.get("list")).size() == 3 && number(search.get("total")) == 3,
                "original search/page producer must survive Java RPC");
    }

    private void vertical() throws Exception {
        Map<String,Object> search = call("categoryContent", Map.of("tid", "huya/s/" + encode("主播 中文"), "pg", "1"));
        check("huya:12345".equals(object(list(search.get("list")).get(0)).get("vod_id")),
                "original Huya search through actual RuntimeNet must produce the room");
        Map<String,Object> play = call("playerContent", Map.of("id", "huya:12345", "flag", "虎牙"));
        Map<?,?> urls = object(play.get("url"));
        List<?> values = list(urls.get("values"));
        check(values.size() == 2 && number(urls.get("position")) == 0 && number(play.get("position")) == 0,
                "original two-CDN values/selected index/live zero position must remain structured");
        check("A".equals(object(values.get(0)).get("n")) && "B".equals(object(values.get(1)).get("n")), "original CDN priorities");
        check("video/x-flv".equals(play.get("format")) && number(play.get("parse")) == 0, "original direct FLV format");
        check((upstream + "/").equals(object(play.get("header")).get("Referer")), "original playback headers survive RPC");
        String firstUrl = string(object(values.get(0)).get("v"));
        String secondUrl = string(object(values.get(1)).get("v"));
        String startUrl = string(object(list(play.get("danmaku")).get(0)).get("url"));
        checkRoute(firstUrl, "/script-proxy");
        checkRoute(secondUrl, "/script-proxy");
        checkRoute(startUrl, "/script-danmaku/start");
        HttpResponse<String> head = request(firstUrl, "HEAD", null);
        check(head.statusCode() == 200 && head.headers().firstValue("Content-Type").orElse("").equals("video/x-flv"),
                "real registered HTTP proxy must expose author FLV response headers");
        Map<String,Object> started = start(startUrl);
        check(string(started.get("generation")).matches("[0-9a-f]{32}"), "real Java generation is a 32hex string");
        pollUntil(started, "原作者彩色弹幕", false);
        check(polls.stream().anyMatch(p -> "ready".equals(object(p.get("state")).get("state"))), "ready must come from original Huya acknowledgement");
        check(events().stream().anyMatch(event -> "原作者彩色弹幕".equals(event.get("text"))
                        && list(event.get("colors")).equals(List.of(0x112233L, 0x445566L))), "original multicolor chat survives raw Java JSON");
        PySpider spider = registered(firstUrl);
        try (PyProxyResponse first = spider.callProxy(proxyParams(firstUrl));
             PyProxyResponse sibling = spider.callProxy(proxyParams(secondUrl))) {
            check(first.status == 200 && first.mime.equals("video/x-flv") && first.contentLength == -1,
                    "original generator must cross runner as an owned streaming response");
            check(first.headers.get("Cache-Control").equals("no-store") && first.headers.get("Accept-Ranges").equals("none"),
                    "original streaming headers remain intact");
            verifyFlv(first.body.readNBytes(13 + TAG_LENGTH), true, 0);
            verifyFlv(sibling.body.readNBytes(13 + TAG_LENGTH), true, 0);
            CountDownLatch entered = new CountDownLatch(1);
            CompletableFuture<Boolean> pending = new CompletableFuture<>();
            Thread reader = new Thread(() -> {
                entered.countDown();
                try { first.body.read(); pending.complete(false); }
                catch (IOException closed) { pending.complete(true); }
                catch (Throwable error) { pending.completeExceptionally(error); }
            }, "author-original-flv-blocked");
            reader.setDaemon(true);
            reader.start();
            check(entered.await(1, TimeUnit.SECONDS), "blocked read entered");
            Thread.sleep(100);
            check(!pending.isDone(), "original FLV read must genuinely block on its upstream socket");
            chat("阻塞期间弹幕");
            pollUntil(started, "阻塞期间弹幕", false);
            long begin = System.nanoTime();
            first.close();
            cancellationMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - begin);
            check(cancellationMillis < 1500 && pending.get(2, TimeUnit.SECONDS), "cancel only the blocked original handle promptly");
            reader.join(1000);
            check(!reader.isAlive(), "cancelled original reader thread must terminate");
            await(() -> streamClosed("A"), 2000, "cancelled upstream socket closes");
            check(!streamClosed("B"), "sibling upstream socket must remain open");
            request(upstream + "/advance?cdn=B", "GET", null);
            verifyFlv(sibling.body.readNBytes(TAG_LENGTH), false, 1000);
            chat("取消后弹幕继续");
            pollUntil(started, "取消后弹幕继续", false);
            checkSameChild();
            Map<String,Object> after = call("playerContent", Map.of("id", "huya:12345"));
            check(startUrl.equals(object(list(after.get("danmaku")).get(0)).get("url")), "registered owner remains the same after stream cancellation");
        }
        await(() -> streamClosed("B"), 2000, "sibling closes independently");
        checkSameChild();
        ProcessHandle child = ProcessHandle.of(childPid).orElseThrow();
        check(child.destroy(), "fixture-owned child exit must be triggered explicitly");
        child.onExit().get(3, TimeUnit.SECONDS);
        pollUntil(started, null, true);
        Map<String,Object> stop = JsonCodec.parseObject(request(string(started.get("stopUrl")), "POST", "").body());
        check(Boolean.TRUE.equals(stop.get("closed")), "real stop confirms terminal subscription");
        check(request(string(started.get("eventsUrl")), "GET", null).statusCode() == 404, "stopped subscription revoked");
        Map<String,Object> capture = new LinkedHashMap<>();
        capture.put("startUrl", startUrl);
        capture.put("started", started);
        capture.put("polls", polls);
        capture.put("provenance", provenance(play));
        Path exported = root.resolve("java-danmaku-capture.json");
        Files.writeString(exported, JsonCodec.stringify(capture), StandardCharsets.UTF_8);
        reset();
        check(request(firstUrl, "HEAD", null).statusCode() == 404, "reset revokes original stream registration");
        check(request(startUrl, "POST", "").statusCode() == 404, "reset revokes original danmaku registration");
        smoke();
        Map<String,Object> freshPlay = call("playerContent", Map.of("id", "huya:12345"));
        String freshStart = string(object(list(freshPlay.get("danmaku")).get(0)).get("url"));
        Map<String,Object> fresh = start(freshStart);
        check(!started.get("generation").equals(fresh.get("generation")) && !startUrl.equals(freshStart), "reload has fresh owner and generation");
        check(observations("loaded").size() == 2 && number(observations("loaded").get(1).get("pid")) != childPid, "reload starts a new original child only after reset");
        request(string(fresh.get("stopUrl")), "POST", "");
        reset();
        check(list(status().get("errors")).isEmpty(), "offline fixture must report no protocol or upstream errors");
        System.out.println("PASS original search/playback/FLV >64KiB and Huya real ready/chat with same-child cancellation (" + cancellationMillis + "ms)");
        System.out.println("PASS explicit child EOF, stop, reset and fresh generation isolation");
        System.out.println("Java capture: " + exported);
    }

    private Map<String,Object> provenance(Map<String,Object> play) throws Exception {
        Map<String,Object> value = new LinkedHashMap<>();
        value.put("testName", "AuthorGameRuntimeTest: original entry/helpers -> Java FLV + Huya chat -> independent cancellation/EOF/reset");
        value.put("capturedAt", Instant.now().toString()); value.put("author", author.toString());
        value.put("sourceSha256", hashes); value.put("fixture", repo.resolve("companion/pyshell/tests/author_game_fixture.py").toString());
        value.put("javaTest", repo.resolve("android-bridge/test/com/fongmi/companion/AuthorGameRuntimeTest.java").toString());
        value.put("classpath", System.getProperty("java.class.path")); value.put("python", System.getProperty("xiugou.python"));
        value.put("originalApi", api); value.put("childPid", childPid); value.put("cancelMs", cancellationMillis);
        value.put("rawPlayerContent", play); value.put("upstream", ready); value.put("observations", observations(null));
        value.put("upstreamState", status()); value.put("publicNetworkVerified", false);
        value.put("patches", List.of("author.HUYA loopback constant", "HttpExchange._request URL destination only; real method/body/headers/SDK retained",
                "WebSocketExchange constructor URL destination only; original Huya protocol and RuntimeNet retained"));
        value.put("proof", List.of("original four source hashes unchanged", "real Java HTTP start/poll JSON objects without schema conversion",
                "same PID/generation, original chat and sibling FLV survive blocked handle close", "terminal closed poll caused by explicit test child exit after cancellation proof"));
        return value;
    }

    private void checkSameChild() throws Exception {
        check(observations("loaded").size() == 1 && ProcessHandle.of(childPid).map(ProcessHandle::isAlive).orElse(false),
                "cancel must retain the original live child, without restart/reconnect substitution");
        check(list(status().get("websockets")).size() == 1 && !Boolean.TRUE.equals(object(list(status().get("websockets")).get(0)).get("closed")),
                "the original Huya WebSocket must survive without reconnect");
    }

    private PySpider registered(String url) throws Exception {
        Field field = SpiderServer.class.getDeclaredField("loader");
        field.setAccessible(true);
        DexSpiderLoader loader = (DexSpiderLoader) field.get(bridge);
        PySpider result = loader.registeredScript(query(url).get("token"), SITE);
        check(result != null, "inspect the actual registered instance; never create another PySpider");
        return result;
    }
    private void checkRoute(String url, String path) {
        check(url.startsWith(base + path + "?") && SITE.equals(query(url).get("siteKey")) && "py".equals(query(url).get("do"))
                && !query(url).getOrDefault("token", "").isBlank(), "host-owned loopback routing survives raw playerContent");
    }
    private static Map<String,String> proxyParams(String url) {
        Map<String,String> result = query(url); result.remove("token"); result.remove("do"); result.remove("siteKey"); return result;
    }
    private Map<String,Object> start(String url) throws Exception {
        HttpResponse<String> response = request(url, "POST", "");
        check(response.statusCode() == 200, "actual Java start: " + response.statusCode() + " " + response.body());
        return JsonCodec.parseObject(response.body());
    }
    private void pollUntil(Map<String,Object> subscription, String text, boolean closed) throws Exception {
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        long after = polls.isEmpty() ? 0 : number(polls.get(polls.size() - 1).get("cursor"));
        while (System.nanoTime() < end) {
            HttpResponse<String> response = request(subscription.get("eventsUrl") + "&after=" + after + "&wait=100", "GET", null);
            check(response.statusCode() == 200, "actual Java poll " + response.statusCode());
            Map<String,Object> poll = JsonCodec.parseObject(response.body());
            check(subscription.get("generation").equals(poll.get("generation")), "same generation in every raw poll");
            polls.add(poll); after = number(poll.get("cursor"));
            if (closed ? Boolean.TRUE.equals(poll.get("closed")) : events().stream().anyMatch(event -> text.equals(event.get("text")))) return;
            check(!Boolean.TRUE.equals(poll.get("closed")), "live original subscription unexpectedly ended");
        }
        throw new AssertionError("missing original protocol event: " + (closed ? "closed" : text));
    }
    private List<Map<?,?>> events() {
        List<Map<?,?>> result = new ArrayList<>();
        for (Map<String,Object> poll : polls)
            for (Object event : list(poll.get("events"))) result.add(object(object(event).get("item")));
        return result;
    }
    private void chat(String text) throws Exception {
        Map<String,Object> result = JsonCodec.parseObject(request(upstream + "/chat?text=" + encode(text), "GET", null).body());
        check(number(result.get("sent")) == 1, "chat must use the original single WebSocket");
    }
    private boolean streamClosed(String cdn) {
        try {
            for (Object item : list(status().get("streams"))) {
                Map<?,?> stream = object(item);
                if (cdn.equals(stream.get("cdn"))) return Boolean.TRUE.equals(stream.get("closed"));
            }
            return false;
        } catch (Exception error) { throw new IllegalStateException(error); }
    }
    private static void verifyFlv(byte[] bytes, boolean header, int stamp) {
        int offset = header ? 13 : 0;
        check(bytes.length == offset + TAG_LENGTH, "whole >64KiB tag survives lazy bounded Java reads");
        if (header) check(Arrays.equals(Arrays.copyOf(bytes, 4), new byte[]{70, 76, 86, 1}), "original FLV header");
        check(bytes[offset] == 9 && (bytes[offset + 1] & 255) * 65536 + (bytes[offset + 2] & 255) * 256 + (bytes[offset + 3] & 255) == 90 * 1024,
                "complete original FLV tag framing");
        check(((bytes[offset + 4] & 255) << 16 | (bytes[offset + 5] & 255) << 8 | bytes[offset + 6] & 255) == stamp,
                "original timestamp progression remains intact");
        check(bytes[offset + 11] == 0x17 && bytes[offset + 12] == 1, "original video payload");
    }
    private Map<String,Object> descriptor() {
        Map<String,Object> result = new LinkedHashMap<>(); result.put("siteKey", SITE); result.put("key", SITE);
        result.put("api", api); result.put("ext", ""); result.put("jar", ""); result.put("timeoutMs", 10000); return result;
    }
    @SuppressWarnings("unchecked")
    private Map<String,Object> call(String method, Map<String,Object> arguments) throws Exception {
        Map<String,Object> body = descriptor(); body.put("method", method); body.putAll(arguments);
        Object data = rpc("/spider/call", body).get("data");
        if (data instanceof String) return JsonCodec.parseObject((String)data);
        check(data instanceof Map, "raw Java call object " + method); return (Map<String,Object>) data;
    }
    private Map<String,Object> rpc(String route, Map<String,Object> body) throws Exception {
        HttpResponse<String> response = request(base + route, "POST", JsonCodec.stringify(body));
        check(response.statusCode() == 200, "RPC status " + response.statusCode() + " " + response.body());
        Map<String,Object> envelope = JsonCodec.parseObject(response.body());
        check(number(envelope.get("code")) == 0, "RPC failure " + response.body()); return envelope;
    }
    private void reset() throws Exception { rpc("/spider/reset", Map.of()); }
    private Map<String,Object> status() throws Exception { return JsonCodec.parseObject(request(upstream + "/status", "GET", null).body()); }
    private List<Map<String,Object>> observations(String kind) throws Exception {
        List<Map<String,Object>> result = new ArrayList<>();
        for (String line : Files.readAllLines(root.resolve("child-observations.jsonl"), StandardCharsets.UTF_8)) {
            Map<String,Object> value = JsonCodec.parseObject(line);
            if (kind == null || kind.equals(value.get("kind"))) result.add(value);
        }
        return result;
    }
    private static boolean hasRequest(Map<String,Object> status, String path) {
        return list(status.get("requests")).stream().anyMatch(item -> path.equals(object(item).get("path")));
    }
    private Map<String,Object> sourceHashes() throws Exception {
        Map<String,Object> result = new LinkedHashMap<>();
        for (String name : SOURCES) result.put(name, HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(author.resolveSibling(name)))));
        return result;
    }
    private void checkHashes() throws Exception { check(hashes.equals(sourceHashes()), "all four original source files remain byte-for-byte unchanged"); }
    private static HttpResponse<String> request(String url, String method, String body) throws Exception {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(10)).header("Content-Type", "application/json")
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body))
                .build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
    }
    private static Map<String,String> query(String url) {
        Map<String,String> result = new LinkedHashMap<>();
        for (String item : URI.create(url).getRawQuery().split("&")) {
            String[] pair = item.split("=", 2);
            check(result.put(URLDecoder.decode(pair[0], StandardCharsets.UTF_8), URLDecoder.decode(pair.length == 1 ? "" : pair[1], StandardCharsets.UTF_8)) == null, "duplicate routing query");
        }
        return result;
    }
    private static String encode(String text) { return java.net.URLEncoder.encode(text, StandardCharsets.UTF_8).replace("+", "%20"); }
    private static String string(Object value) { check(value instanceof String, "expected protocol string"); return (String)value; }
    private static long number(Object value) { check(value instanceof Number, "expected protocol number: " + value); return ((Number)value).longValue(); }
    private static Map<?,?> object(Object value) { check(value instanceof Map, "expected protocol object: " + value); return (Map<?,?>)value; }
    private static List<?> list(Object value) { check(value instanceof List, "expected protocol list: " + value); return (List<?>)value; }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void await(BooleanSupplier ready, long millis, String message) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(millis);
        while (!ready.getAsBoolean()) { if (System.nanoTime() > deadline) throw new AssertionError(message); Thread.sleep(10); }
    }
    @Override public void close() throws Exception {
        try {
            try { if (bridge != null) bridge.stop(); }
            finally {
                Files.writeString(root.resolve("stop"), "stop");
                if (fixture != null) {
                    boolean stopped;
                    try { stopped = fixture.waitFor(3, TimeUnit.SECONDS); }
                    finally { if (fixture.isAlive()) fixture.destroyForcibly(); }
                    if (!stopped) fixture.waitFor(2, TimeUnit.SECONDS);
                    check(stopped, "upstream fixture must close cooperatively");
                    check(fixture.exitValue() == 0, "upstream fixture protocol/cleanup failed; inspect " + root.resolve("upstream.stderr.log"));
                }
            }
        } finally {
            if (previousHome == null) System.clearProperty("user.home"); else System.setProperty("user.home", previousHome);
            System.out.println("Retained test-only artifacts: " + root);
        }
    }
}
