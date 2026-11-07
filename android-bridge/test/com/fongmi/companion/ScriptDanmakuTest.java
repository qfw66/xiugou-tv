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
import java.util.stream.Stream;

/** Real HTTP/runner ownership. No public upstream, author edits or packaged output. */
public final class ScriptDanmakuTest {
    private static final HttpClient HTTP = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
    private static final String SCRIPT = """
            import json, os, threading, time
            from pathlib import Path
            from urllib.parse import urlencode
            class Spider:
                def init(self, ext=''):
                    self.root = Path(ext)
                    self.stop = None
                    self.init_env = {key:os.environ.get(key) for key in ('XIUGOU_SCRIPT_API',
                        'XIUGOU_SCRIPT_BASE','XIUGOU_SCRIPT_SITE_KEY','XIUGOU_SCRIPT_DANMAKU_BASE',
                        'XIUGOU_LOCAL_DIR','XIUGOU_NET_CACHE_DIR','XIUGOU_JAVA_BIN','XIUGOU_JAVA_CLASSPATH')}
                def playerContent(self, flag, id, vipFlags):
                    base = os.environ.get('XIUGOU_SCRIPT_DANMAKU_BASE', '')
                    url = base + '&' + urlencode({'do':'py','siteKey':os.environ.get('XIUGOU_SCRIPT_SITE_KEY',''),'id':id})
                    return {'danmaku':[{'name':'live','url':url}]}
                def action(self, value):
                    if value == 'block':
                        (self.root / 'blocked').touch()
                        while not (self.root / 'release').exists(): time.sleep(.005)
                    if value == 'die': os._exit(0)
                    return {'pid':os.getpid(),'value':value,'env':self.init_env}
                def danmaku(self, room, emit):
                    if self.stop: self.stop()
                    print('ordinary-print-is-not-event')
                    event = threading.Event()
                    def stop():
                        if event.is_set(): return
                        event.set()
                        with (self.root / 'stops').open('a') as out: out.write(room + '\\n')
                        emit({'text':'late-stop','color':1})
                    self.stop = stop
                    emit({'state':'ready'})
                    if room.startswith('early-'):
                        (self.root / (room + '-entered')).touch()
                        while not (self.root / (room + '-release')).exists(): time.sleep(.005)
                    if room == 'burst':
                        for i in range(400):
                            emit({'text':str(i),'color':0x0080ff})
                            time.sleep(.001)
                    if room != 'silent': emit({'text':room,'color':0x0080ff,'colors':[1,0xffffff]})
                    return stop
                def destroy(self):
                    if self.stop: self.stop()
            """;
    private final List<String> failures = new ArrayList<>();
    private Path root, script;
    private SpiderServer server;
    private String base, previousHome;

    public static void main(String[] args) throws Exception {
        ScriptDanmakuTest t = new ScriptDanmakuTest();
        t.root = Files.createTempDirectory("xiugou-danmaku-http-").toAbsolutePath();
        t.script = t.root.resolve("source.py");
        Files.writeString(t.script, SCRIPT, StandardCharsets.UTF_8);
        t.previousHome = System.getProperty("user.home");
        System.setProperty("user.home", t.root.toString());
        System.setProperty("xiugou.py.danmakuLeaseMs", "500");
        t.server = new SpiderServer(0);
        t.base = "http://127.0.0.1:" + t.server.start();
        try {
            t.run("registered start/events/stop with environment", t::basic);
            t.run("lookup only and exact paths", t::routing);
            t.run("stop bypasses blocked ordinary RPC", t::blocked);
            t.run("room replacement retires old subscription", t::replacement);
            t.run("concurrent replacement keeps only the current room", t::concurrentReplacement);
            t.run("reset interrupts pending start without late publication", t::resetPendingStart);
            t.run("reset closes admission through loader retirement", t::resetAdmission);
            t.run("bounded ring reports dropped events", t::overflow);
            t.run("valid polls renew lease and abandonment stops", t::lease);
            t.run("reset revokes instance and subscription", t::reset);
            t.run("child EOF closes subscription without rebinding", t::childExit);
            check(t.failures.isEmpty(), String.join("\n", t.failures));
            System.out.println("ScriptDanmakuTest OK (11 real HTTP/process boundaries)");
        } finally {
            Files.writeString(t.root.resolve("release"), "yes");
            Files.writeString(t.root.resolve("return-stop"), "yes");
            t.server.stop();
            System.clearProperty("xiugou.py.danmakuLeaseMs");
            if (t.previousHome == null) System.clearProperty("user.home"); else System.setProperty("user.home", t.previousHome);
            check(t.root.isAbsolute() && t.root.getFileName().toString().startsWith("xiugou-danmaku-http-"), "own cleanup root");
            try (Stream<Path> paths = Files.walk(t.root)) {
                for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
            }
        }
    }
    private void run(String label, Checked work) {
        try { work.run(); System.out.println("PASS " + label); }
        catch (Throwable error) { failures.add(label + ": " + error); error.printStackTrace(); }
    }
    private String address(String room) throws Exception {
        Map<String,Object> result = call("playerContent", List.of("", room, List.of()));
        List<?> list = (List<?>) result.get("danmaku");
        return String.valueOf(((Map<?,?>) list.get(0)).get("url"));
    }
    @SuppressWarnings("unchecked")
    private Map<String,Object> call(String method, List<?> args) throws Exception {
        Map<String,Object> body = new LinkedHashMap<>();
        body.put("siteKey", "game+中文"); body.put("api", script.toUri().toString());
        body.put("ext", root.toString()); body.put("method", method);
        if (method.equals("playerContent")) { body.put("flag", args.get(0)); body.put("id", args.get(1)); }
        if (method.equals("action")) body.put("action", args.get(0));
        HttpResponse<String> response = request(base + "/spider/call", "POST", JsonCodec.stringify(body));
        Map<String,Object> envelope = JsonCodec.parseObject(response.body());
        Object data = envelope.get("data");
        if (data == null) data = envelope.get("result");
        if (data instanceof String) return JsonCodec.parseObject((String)data);
        if (data instanceof Map) return (Map<String,Object>) data;
        throw new AssertionError("RPC response missing result: " + response.body());
    }
    private Map<String,Object> start(String room) throws Exception {
        HttpResponse<String> response = request(address(room), "POST", "");
        check(response.statusCode() == 200, "start " + response.statusCode() + " " + response.body());
        return JsonCodec.parseObject(response.body());
    }
    private Map<String,Object> poll(Map<String,Object> sub, long after, long wait) throws Exception {
        HttpResponse<String> response = request(sub.get("eventsUrl") + "&after=" + after + "&wait=" + wait, "GET", "");
        check(response.statusCode() == 200, "poll " + response.statusCode());
        return JsonCodec.parseObject(response.body());
    }
    private void stop(Map<String,Object> sub) throws Exception {
        HttpResponse<String> response = request(String.valueOf(sub.get("stopUrl")), "POST", "");
        check(response.statusCode() == 200 && Boolean.TRUE.equals(JsonCodec.parseObject(response.body()).get("closed")), "stop");
    }
    private void basic() throws Exception {
        Map<String,Object> sub = start("basic");
        Map<String,Object> events = poll(sub, 0, 50);
        check(!((List<?>)events.get("events")).isEmpty(), "immediate events retained");
        check(((Map<?,?>)events.get("state")).get("state").equals("ready"), "actual ready");
        Map<String,Object> action = call("action", List.of("env"));
        Map<?,?> env = (Map<?,?>) action.get("env");
        check(env.get("XIUGOU_SCRIPT_API").equals(script.toUri().toString()), "original api at init");
        check(URI.create(String.valueOf(env.get("XIUGOU_SCRIPT_BASE"))).equals(root.toUri()), "original module base at init");
        check("game+中文".equals(env.get("XIUGOU_SCRIPT_SITE_KEY")), "site identity at init");
        check(String.valueOf(env.get("XIUGOU_SCRIPT_DANMAKU_BASE")).startsWith(base + "/script-danmaku/start?token="), "danmaku owner at init");
        check(Path.of(String.valueOf(env.get("XIUGOU_LOCAL_DIR"))).equals(root.resolve(".xiugou_tv_companion/py-local")), "local path at init");
        check(Path.of(String.valueOf(env.get("XIUGOU_NET_CACHE_DIR"))).equals(root.resolve(".xiugou_tv_companion/py-net-cache")), "persistent cache");
        check(Files.isRegularFile(Path.of(String.valueOf(env.get("XIUGOU_JAVA_BIN")))), "java executable");
        for (String entry : String.valueOf(env.get("XIUGOU_JAVA_CLASSPATH")).split(java.util.regex.Pattern.quote(java.io.File.pathSeparator)))
            check(Path.of(entry).isAbsolute(), "absolute classpath");
        stop(sub); stop(sub);
        check(request(String.valueOf(sub.get("eventsUrl")), "GET", "").statusCode() == 404, "stopped events revoked");
    }
    private void routing() throws Exception {
        check(request(base + "/script-danmaku/start?token=unknown&do=py&siteKey=x&id=room&api=" + script.toUri(), "POST", "").statusCode() == 404, "no API load");
        String url = address("route");
        check(request(url + "&token=override", "POST", "").statusCode() == 400, "duplicate routing rejected");
        check(request(url.replace("/start?", "/startX?"), "POST", "").statusCode() == 404, "exact path");
        check(request(url, "GET", "").statusCode() == 405, "GET cannot start");
    }
    private void blocked() throws Exception {
        Map<String,Object> sub = start("blocked");
        Map<String,Object> before = call("action", List.of("pid"));
        CompletableFuture<Map<String,Object>> call = CompletableFuture.supplyAsync(() -> {
            try { return call("action", List.of("block")); } catch (Exception e) { throw new RuntimeException(e); }
        });
        await(() -> Files.exists(root.resolve("blocked")), 2000, "blocked call entered");
        long begin = System.nanoTime();
        stop(sub);
        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-begin) < 1000, "stop bypasses call");
        check(!call.isDone(), "ordinary call still blocked");
        Files.writeString(root.resolve("release"), "yes");
        check(before.get("pid").equals(call.get(3, TimeUnit.SECONDS).get("pid")), "same child remains");
    }
    private void replacement() throws Exception {
        Map<String,Object> first = start("old"), second = start("new");
        check(Boolean.TRUE.equals(poll(first, 0, 0).get("closed")), "old owner retired");
        check(!Boolean.TRUE.equals(poll(second, 0, 0).get("closed")), "new owner active");
        stop(first); stop(second);
    }
    private void concurrentReplacement() throws Exception {
        String firstUrl = address("early-replace"), nextUrl = address("newest");
        Object pid = call("action", List.of("before-replace")).get("pid");
        CompletableFuture<HttpResponse<String>> first = postAsync(firstUrl);
        await(() -> Files.exists(root.resolve("early-replace-entered")), 2000, "first start entered");
        CompletableFuture<HttpResponse<String>> next = postAsync(nextUrl);
        try {
            Thread.sleep(100);
            check(!first.isDone() && !next.isDone(), "replacement waits for original start cleanup");
        } finally {
            Files.writeString(root.resolve("early-replace-release"), "yes");
        }
        check(first.get(3, TimeUnit.SECONDS).statusCode() == 502, "superseded start is not published");
        HttpResponse<String> response = next.get(3, TimeUnit.SECONDS);
        check(response.statusCode() == 200, "replacement start succeeds");
        Map<String,Object> sub = JsonCodec.parseObject(response.body());
        check(!Boolean.TRUE.equals(poll(sub, 0, 0).get("closed")), "new room active");
        check(pid.equals(call("action", List.of("after-replace")).get("pid")), "replacement keeps original child");
        check(Files.readAllLines(root.resolve("stops")).stream().filter("early-replace"::equals).count() == 1,
                "cancel-before-return stops original once");
        stop(sub);
    }
    private void resetPendingStart() throws Exception {
        String old = address("early-reset");
        CompletableFuture<HttpResponse<String>> pending = postAsync(old);
        await(() -> Files.exists(root.resolve("early-reset-entered")), 2000, "pending start entered");
        long begin = System.nanoTime();
        check(request(base + "/spider/reset", "POST", "{}").statusCode() == 200, "reset response");
        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - begin) < 2000, "reset bounded during start");
        check(pending.get(3, TimeUnit.SECONDS).statusCode() == 502, "pending start never published");
        check(request(old, "POST", "").statusCode() == 404, "old token remains revoked");
        stop(start("after-reset"));
    }
    private void resetAdmission() throws Exception {
        com.fongmi.companion.py.PySpider spider = new com.fongmi.companion.py.PySpider(
                script.toUri().toString(), root.toString(), root.toFile());
        spider.init(null, root.toString());
        java.util.concurrent.CountDownLatch retiring = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
        try (ScriptDanmakuRegistry registry = new ScriptDanmakuRegistry()) {
            ScriptDanmakuRegistry.Entry old = registry.start(spider, "admission-old");
            CompletableFuture<Integer> reset = CompletableFuture.supplyAsync(() -> registry.reset(() -> {
                retiring.countDown();
                try { check(release.await(3, TimeUnit.SECONDS), "reset release gate"); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new RuntimeException(error); }
                spider.destroy();
                return 1;
            }));
            try {
                check(retiring.await(2, TimeUnit.SECONDS), "loader retirement entered");
                check(old.poll(0, 0) == null, "existing lease revoked before loader closes");
                boolean rejected = false;
                try { registry.start(spider, "admission-late"); }
                catch (IllegalStateException expected) { rejected = true; }
                check(rejected, "pre-resolved child cannot start during loader retirement");
            } finally { release.countDown(); }
            check(reset.get(3, TimeUnit.SECONDS) == 1, "reset release result");
            com.fongmi.companion.py.PySpider fresh = new com.fongmi.companion.py.PySpider(
                    script.toUri().toString(), root.toString(), root.toFile());
            fresh.init(null, root.toString());
            try {
                ScriptDanmakuRegistry.Entry next = registry.start(fresh, "admission-fresh");
                check(!Boolean.TRUE.equals(next.poll(0, 0).get("closed")), "admission resumes for new child");
                registry.stop(next.id, next.generation());
            } finally { fresh.destroy(); }
        } finally { release.countDown(); spider.destroy(); }
    }
    private static CompletableFuture<HttpResponse<String>> postAsync(String url) {
        return HTTP.sendAsync(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(5))
                .POST(HttpRequest.BodyPublishers.noBody()).build(), HttpResponse.BodyHandlers.ofString());
    }
    private void overflow() throws Exception {
        Map<String,Object> sub = start("burst");
        Map<String,Object> result = poll(sub, 0, 0);
        check(((List<?>)result.get("events")).size() <= 256, "bounded ring");
        check(((Number)result.get("dropped")).longValue() > 0, "overflow observable");
        check(((Map<?,?>)result.get("state")).get("state").equals("ready"), "state survives overflow");
        stop(sub);
    }
    private void lease() throws Exception {
        Map<String,Object> sub = start("silent");
        long cursor = ((Number)poll(sub,0,0).get("cursor")).longValue();
        for (int i=0;i<4;i++) check(!Boolean.TRUE.equals(poll(sub,cursor,200).get("closed")), "empty poll renews");
        await(() -> request(String.valueOf(sub.get("eventsUrl")) + "&after=invalid", "GET", "").statusCode() == 404,
                3000, "invalid poll does not renew lease");
        check(Files.readString(root.resolve("stops")).contains("silent"), "expired lease stops producer");
    }
    private void reset() throws Exception {
        String old = address("reset");
        Map<String,Object> sub = start("reset");
        request(base + "/spider/reset", "POST", "{}");
        check(request(old, "POST", "").statusCode() == 404, "old instance token revoked");
        check(request(String.valueOf(sub.get("eventsUrl")), "GET", "").statusCode() == 404, "old subscription revoked");
        stop(start("fresh"));
    }
    private void childExit() throws Exception {
        Map<String,Object> sub = start("dead");
        try { call("action", List.of("die")); } catch (Exception | AssertionError expected) { }
        Map<String,Object> result = poll(sub,0,0);
        check(Boolean.TRUE.equals(result.get("closed")), "EOF ends subscription");
        check(((Map<?,?>)result.get("state")).get("state").equals("error"), "safe terminal state");
        CompletableFuture<Map<String,Object>> restart = CompletableFuture.supplyAsync(() -> {
            try { return call("action", List.of("restart")); }
            catch (Exception error) { throw new RuntimeException(error); }
        });
        while (!restart.isDone()) {
            check(Boolean.TRUE.equals(poll(sub,0,0).get("closed")), "closed lease remains independent of restart");
            Thread.sleep(50);
        }
        restart.get(3, TimeUnit.SECONDS);
        check(Boolean.TRUE.equals(poll(sub,0,0).get("closed")), "old handle not rebound");
    }
    private static HttpResponse<String> request(String url, String method, String body) throws Exception {
        HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(5));
        if (method.equals("GET")) builder.GET(); else builder.POST(HttpRequest.BodyPublishers.ofString(body));
        return HTTP.send(builder.build(), HttpResponse.BodyHandlers.ofString());
    }
    private static void await(Check condition, long timeout, String message) throws Exception {
        long end=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(timeout);
        while (!condition.get() && System.nanoTime()<end) Thread.sleep(10);
        check(condition.get(), message);
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private interface Checked { void run() throws Exception; }
    private interface Check { boolean get() throws Exception; }
}
