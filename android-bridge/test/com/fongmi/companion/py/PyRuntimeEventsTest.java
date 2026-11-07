package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

/** Real Python pipes: unsolicited frames, controlled stop, exact-child pins and idle EOF. */
public final class PyRuntimeEventsTest {
    private static final String SCRIPT = """
            import json, os, sys, threading, time
            from pathlib import Path
            from base.net import RuntimeNet
            class Spider:
                def init(self, ext=''):
                    self.root = Path(ext)
                    self._net = RuntimeNet()
                def action(self, value):
                    return {'pid':os.getpid(),'value':value}
                def proxy(self, params):
                    kind = params.get('kind', 'http')
                    if kind in ('generator', 'uncooperative'):
                        def chunks():
                            if kind == 'uncooperative':
                                (self.root / 'reading').touch()
                                time.sleep(10)
                                yield b'late'
                                return
                            reader = self._net.openStream(params['url'], {'timeout':5000,'callTimeout':0})
                            try:
                                (self.root / 'reading').touch()
                                while True:
                                    data = reader.read(65536)
                                    if data is None: return
                                    yield data
                            finally:
                                reader.close()
                                (self.root / 'finished').touch()
                        return [200, 'video/x-flv', self._net.stream(chunks())['stream']]
                    reader = self._net.openStream(params['url'], {'timeout':5000,'callTimeout':0})
                    read = reader.read
                    def marked(size=65536):
                        (self.root / 'reading').touch()
                        return read(size)
                    reader.read = marked
                    return [reader.code, reader.contentType, reader, reader.headers]
                def danmaku(self, room, emit):
                    print('ordinary-log-not-event')
                    emit({'state':'ready'})
                    closed = threading.Event()
                    def stop():
                        if closed.is_set(): return
                        closed.set()
                        with (self.root / 'stops').open('a') as out: out.write(room + '\\n')
                        emit({'text':'late-after-stop','color':1})
                        if room == 'bad-stop': raise RuntimeError('sensitive stop detail')
                    if room == 'early':
                        (self.root / 'entered').touch()
                        while not (self.root / 'return-stop').exists(): time.sleep(.005)
                    def events():
                        if room == 'idle-exit':
                            while not (self.root / 'die').exists(): time.sleep(.005)
                            os._exit(0)
                        if room == 'stale':
                            import __main__
                            owner = emit.__self__
                            for sid, generation in ((owner.subscription, '0'*32), ('f'*32, owner.generation)):
                                __main__._reply({'type':'event','topic':'danmaku','subscriptionId':sid,
                                    'generation':generation,'seq':999,'item':{'text':'stale','color':1}})
                        index = 0
                        while room == 'continuous' or index < 5:
                            if closed.wait(.01): return
                            emit({'text':room+':'+str(index),'color':0x0080ff,'colors':[1,0xffffff]})
                            index += 1
                    threading.Thread(target=events, daemon=True).start()
                    return stop
            """;

    public static void main(String[] args) throws Exception {
        System.setProperty("xiugou.py.maxProcesses", "1");
        List<String> failures = new ArrayList<>();
        run(failures, "idle events and request ids stay separate", PyRuntimeEventsTest::idleEvents);
        run(failures, "cancel before return retains pin until late stop", PyRuntimeEventsTest::earlyCancel);
        run(failures, "active subscription prevents LRU and stop releases pin", PyRuntimeEventsTest::pin);
        run(failures, "stop bypasses pending stream chunk without retiring child", PyRuntimeEventsTest::blockedStream);
        run(failures, "stop failure retires original child", PyRuntimeEventsTest::failedStop);
        run(failures, "idle EOF ends listener and never rebinds", PyRuntimeEventsTest::idleExit);
        run(failures, "old generation and foreign events are ignored", PyRuntimeEventsTest::staleEvents);
        run(failures, "close before start neither starts nor retains child", PyRuntimeEventsTest::closeBeforeStart);
        run(failures, "HTTP read cancellation preserves sibling and danmaku", () -> isolatedStreamCancel("http", false));
        run(failures, "generator cancellation preserves sibling and danmaku", () -> isolatedStreamCancel("generator", false));
        run(failures, "interrupted generator read preserves sibling and danmaku", () -> isolatedStreamCancel("generator", true));
        run(failures, "uncooperative generator retires only original child", PyRuntimeEventsTest::uncooperativeStream);
        run(failures, "effective entry reaches init without changing source identity", PyRuntimeEventsTest::effectiveEntry);
        check(failures.isEmpty(), String.join("\n", failures));
        System.out.println("PyRuntimeEventsTest OK (13 real process boundaries)");
    }

    private static void run(List<String> failures, String name, Checked work) {
        try { work.run(); System.out.println("PASS " + name); }
        catch (Throwable error) { failures.add(name + ": " + error); error.printStackTrace(); }
    }

    private static void idleEvents() throws Exception {
        try (Fixture f = new Fixture()) {
            Listener listener = new Listener();
            try (PyRuntime.DanmakuSession session = f.open(listener)) {
                session.start("idle");
                await(() -> listener.texts().contains("idle:4"), 2000, "event delivered without another RPC");
                for (int index = 0; index < 10; index++)
                    check(f.action("call-" + index).get("value").equals("call-" + index), "matching response id");
                check(listener.items.stream().anyMatch(item -> List.of(1L, 0xffffffL).equals(item.get("colors"))), "RGB list preserved");
            }
            check(listener.closed.getCount() == 0, "close delivered");
            check(f.stops().equals(List.of("idle")), "one original stop");
        }
    }

    private static void earlyCancel() throws Exception {
        try (Fixture f = new Fixture()) {
            Listener listener = new Listener();
            PyRuntime.DanmakuSession session = f.open(listener);
            CompletableFuture<Void> start = CompletableFuture.runAsync(() -> {
                try { session.start("early"); } catch (Exception error) { throw new RuntimeException(error); }
            });
            await(() -> Files.exists(f.root.resolve("entered")), 2000, "start entered");
            session.close();
            check(f.stops().isEmpty(), "late stop has not returned yet");
            check(!f.spider.evictIdle(), "cancelled start must retain child until original stop returns");
            Files.writeString(f.root.resolve("return-stop"), "yes");
            start.get(3, TimeUnit.SECONDS);
            session.close();
            check(f.stops().equals(List.of("early")), "late stop exactly once");
            check(!listener.texts().contains("late-after-stop"), "late event rejected");
            check(f.spider.evictIdle(), "late start completion releases pin");
        }
    }

    private static void pin() throws Exception {
        try (Fixture f = new Fixture()) {
            Listener listener = new Listener();
            PyRuntime.DanmakuSession session = f.open(listener);
            session.start("pinned");
            check(!f.spider.evictIdle(), "active subscription pins original runtime");
            try (Fixture other = new Fixture()) {
                PyProcessPool.awaitIdle();
                check(f.spider.hasLiveRuntime(), "LRU skips original producer");
            }
            session.close();
            check(f.spider.evictIdle(), "stop releases retained runtime");
        }
    }

    private static void blockedStream() throws Exception {
        CountDownLatch readEntered = new CountDownLatch(1), release = new CountDownLatch(1);
        HttpServer upstream = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        upstream.createContext("/stream", exchange -> {
            try {
                exchange.getResponseHeaders().set("Content-Type", "application/octet-stream");
                exchange.sendResponseHeaders(200, 3);
                exchange.getResponseBody().flush();
                readEntered.countDown();
                release.await(5, TimeUnit.SECONDS);
                exchange.getResponseBody().write(new byte[]{0, (byte) 0x80, (byte) 0xff});
            } catch (Exception ignored) { }
            finally { exchange.close(); }
        });
        upstream.start();
        try (Fixture f = new Fixture()) {
            Object pid = f.action("pid").get("pid");
            PyRuntime.DanmakuSession session = f.open(new Listener());
            session.start("stream");
            try (PyProxyResponse response = f.spider.callProxy(Map.of("url", "http://127.0.0.1:" + upstream.getAddress().getPort() + "/stream"))) {
                CompletableFuture<Integer> read = CompletableFuture.supplyAsync(() -> {
                    try { return response.body.read(); } catch (Exception error) { throw new RuntimeException(error); }
                });
                check(readEntered.await(2, TimeUnit.SECONDS), "upstream read pending");
                // The producer's first chunk is blocked; stop must use the separate control lane.
                long begin = System.nanoTime();
                session.close();
                check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - begin) < 1000, "stop bypasses pending chunk");
                check(!read.isDone(), "stream not cancelled by danmaku stop");
                release.countDown();
                check(read.get(3, TimeUnit.SECONDS) == 0, "pending stream response still matched");
            }
            check(pid.equals(f.action("after").get("pid")), "same child after controlled stop");
        } finally { release.countDown(); upstream.stop(0); }
    }

    private static void isolatedStreamCancel(String kind, boolean interrupt) throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        HttpServer upstream = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        upstream.createContext("/small", exchange -> {
            try {
                exchange.sendResponseHeaders(200, 3);
                exchange.getResponseBody().write(new byte[]{0, (byte) 0x80, (byte) 0xff});
            } finally { exchange.close(); }
        });
        upstream.createContext("/blocked", exchange -> {
            try {
                exchange.sendResponseHeaders(200, 3);
                exchange.getResponseBody().flush();
                release.await(5, TimeUnit.SECONDS);
                exchange.getResponseBody().write(new byte[]{0, (byte) 0x80, (byte) 0xff});
            } catch (Exception ignored) { }
            finally { exchange.close(); }
        });
        upstream.start();
        String base = "http://127.0.0.1:" + upstream.getAddress().getPort();
        try (Fixture f = new Fixture()) {
            Object pid = f.action("before").get("pid");
            Listener listener = new Listener();
            try (PyRuntime.DanmakuSession session = f.open(listener);
                 PyProxyResponse sibling = f.spider.callProxy(Map.of("url", base + "/small"));
                 PyProxyResponse target = f.spider.callProxy(Map.of("url", base + "/blocked", "kind", kind))) {
                session.start("continuous");
                java.util.concurrent.atomic.AtomicReference<Thread> readerThread = new java.util.concurrent.atomic.AtomicReference<>();
                CompletableFuture<Boolean> read = CompletableFuture.supplyAsync(() -> {
                    readerThread.set(Thread.currentThread());
                    try { target.body.read(); return false; }
                    catch (java.io.IOException expected) { return true; }
                    finally { Thread.interrupted(); }
                });
                await(() -> Files.exists(f.root.resolve("reading")), 2000, "SDK read entered");
                check(!read.isDone(), "upstream body is blocked");
                int events = listener.texts().size();
                long begin = System.nanoTime();
                if (interrupt) readerThread.get().interrupt();
                else target.close();
                check(read.get(2, TimeUnit.SECONDS), "cancelled read reports IOException");
                check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - begin) < 1500, "SDK cancel drains promptly");
                check(f.spider.hasLiveRuntime(), "cancelling one SDK stream must preserve original child");
                check(listener.closed.getCount() == 1, "danmaku subscription stays open");
                await(() -> listener.texts().size() > events, 2000, "chat continues after stream cancellation");
                check(java.util.Arrays.equals(sibling.body.readAllBytes(), new byte[]{0, (byte) 0x80, (byte) 0xff}),
                        "sibling stream stays readable");
                check(pid.equals(f.action("after").get("pid")), "cancel preserves original PID and response ids");
                if (kind.equals("generator")) check(Files.exists(f.root.resolve("finished")), "generator finally ran");
                target.close();
            }
            check(f.stops().equals(List.of("continuous")), "danmaku stop exactly once");
            check(f.spider.evictIdle(), "all stream and danmaku pins released");
        } finally { release.countDown(); upstream.stop(0); }
    }

    private static void uncooperativeStream() throws Exception {
        try (Fixture f = new Fixture()) {
            Listener listener = new Listener();
            Object oldPid = f.action("before").get("pid");
            try (PyRuntime.DanmakuSession session = f.open(listener);
                 PyProxyResponse response = f.spider.callProxy(Map.of("kind", "uncooperative"))) {
                session.start("continuous");
                CompletableFuture<Boolean> read = CompletableFuture.supplyAsync(() -> {
                    try { response.body.read(); return false; }
                    catch (java.io.IOException expected) { return true; }
                });
                await(() -> Files.exists(f.root.resolve("reading")), 2000, "non-SDK generator entered");
                long begin = System.nanoTime();
                response.close();
                check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - begin) < 2500, "uncooperative close is bounded");
                check(read.get(2, TimeUnit.SECONDS), "retired read failed");
                check(!f.spider.hasLiveRuntime() && listener.closed.getCount() == 0, "only uncooperative child retired");
                Object newPid = f.action("restart").get("pid");
                check(!oldPid.equals(newPid), "fresh child started");
                response.close(); session.close();
                check(newPid.equals(f.action("still-live").get("pid")), "old cancellation cannot retire replacement");
                try (PyRuntime.DanmakuSession fresh = f.open(new Listener())) {
                    check(!session.generation.equals(fresh.generation), "replacement generation is isolated");
                }
            }
        }
    }

    private static void effectiveEntry() throws Exception {
        Path root = Files.createTempDirectory(Path.of("").toAbsolutePath(), ".xiugou-entry-test-");
        try {
            Path script = root.resolve("source.py");
            Files.writeString(script, """
                    import os
                    class Spider:
                        def init(self, ext=''):
                            self.values = {name:os.environ.get('XIUGOU_SCRIPT_'+name) for name in ('ENTRY','API','BASE')}
                        def action(self): return self.values
                    """, StandardCharsets.UTF_8);
            String relative = Path.of("").toAbsolutePath().relativize(script).toString();
            String remote = "http://127.0.0.1:1/proxy/https://github.com/owner/repo/blob/main/中文.py";
            for (String api : List.of(relative, script.toString(), script.toUri().toString(), remote, "")) {
                java.io.File source = api.equals(remote) || api.isEmpty() ? script.toFile() : PyRuntime.ensureScript(api, root.toFile());
                try (PyRuntime runtime = PyRuntime.start(source, "", root.resolve("stderr.log").toFile(), "site", api, "")) {
                    Map<String, Object> env = JsonCodec.parseObject(runtime.callJson("action", List.of()));
                    String expected = api.equals(remote)
                            ? "http://127.0.0.1:1/proxy/https://raw.githubusercontent.com/owner/repo/main/%E4%B8%AD%E6%96%87.py"
                            : script.toUri().toString();
                    check(expected.equals(env.get("ENTRY")), "effective absolute entry must reach init for " + api);
                    check(api.equals(env.get("API")), "original source identity unchanged");
                    check(PyRuntime.sourceBase(api).equals(env.get("BASE")), "legacy source base unchanged");
                }
            }
        } finally {
            check(root.toAbsolutePath().getParent().equals(Path.of("").toAbsolutePath())
                    && root.getFileName().toString().startsWith(".xiugou-entry-test-"), "own entry test root");
            try (Stream<Path> paths = Files.walk(root)) {
                for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
            }
        }
    }

    private static void failedStop() throws Exception {
        try (Fixture f = new Fixture()) {
            PyRuntime.DanmakuSession session = f.open(new Listener());
            session.start("bad-stop");
            session.close();
            check(!f.spider.hasLiveRuntime(), "failed stop invalidates pipe");
            check(f.stops().equals(List.of("bad-stop")), "failed callback invoked once");
        }
    }

    private static void idleExit() throws Exception {
        try (Fixture f = new Fixture()) {
            Listener listener = new Listener();
            PyRuntime.DanmakuSession session = f.open(listener);
            session.start("idle-exit");
            String generation = session.generation;
            Files.writeString(f.root.resolve("die"), "yes");
            check(listener.closed.await(2, TimeUnit.SECONDS), "idle EOF reaches listener");
            check(session.isClosed(), "old subscription ended");
            f.action("restart");
            try (PyRuntime.DanmakuSession fresh = f.open(new Listener())) {
                check(!generation.equals(fresh.generation), "replacement child has new generation");
                check(session.isClosed(), "old session never rebound");
            }
        }
    }

    private static void staleEvents() throws Exception {
        try (Fixture f = new Fixture()) {
            Listener listener = new Listener();
            try (PyRuntime.DanmakuSession session = f.open(listener)) {
                session.start("stale");
                await(() -> listener.texts().contains("stale:4"), 2000, "valid event after stale sequence");
                check(!listener.texts().contains("stale"), "foreign frames ignored");
                check(f.action("after").get("value").equals("after"), "events never consume RPC response");
            }
        }
    }

    private static void closeBeforeStart() throws Exception {
        try (Fixture f = new Fixture()) {
            PyRuntime.DanmakuSession session = f.open(new Listener());
            session.close();
            session.start("unused");
            check(f.stops().isEmpty(), "never started");
            check(f.spider.evictIdle(), "unused subscription releases pin");
        }
    }

    private static final class Listener implements PyRuntime.DanmakuListener {
        final CopyOnWriteArrayList<Map<String, Object>> items = new CopyOnWriteArrayList<>();
        final CountDownLatch closed = new CountDownLatch(1);
        @Override public void event(long seq, Map<String, Object> item) { items.add(item); }
        @Override public void closed() { closed.countDown(); }
        List<String> texts() {
            List<String> result = new ArrayList<>();
            for (Map<String, Object> item : items) if (item.get("text") instanceof String) result.add((String) item.get("text"));
            return result;
        }
    }

    private static final class Fixture implements AutoCloseable {
        final Path root;
        final PySpider spider;
        Fixture() throws Exception {
            root = Files.createTempDirectory("xiugou-danmaku-runtime-").toAbsolutePath();
            Path script = root.resolve("source.py");
            Files.writeString(script, SCRIPT, StandardCharsets.UTF_8);
            spider = new PySpider(script.toUri().toString(), root.toString(), root.toFile());
            spider.init(null, root.toString());
            check(spider.hasLiveRuntime(), "real child loaded");
        }
        PyRuntime.DanmakuSession open(Listener listener) { return spider.openDanmaku(UUID.randomUUID().toString().replace("-", ""), listener); }
        Map<String, Object> action(String value) throws Exception { return JsonCodec.parseObject(spider.action(value)); }
        List<String> stops() throws Exception { return Files.exists(root.resolve("stops")) ? Files.readAllLines(root.resolve("stops")) : List.of(); }
        @Override public void close() throws Exception {
            Files.writeString(root.resolve("return-stop"), "yes");
            spider.destroy();
            check(root.isAbsolute() && root.getFileName().toString().startsWith("xiugou-danmaku-runtime-"), "own cleanup root");
            try (Stream<Path> paths = Files.walk(root)) {
                for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
            }
        }
    }

    private static void await(Check test, long timeout, String message) throws Exception {
        long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeout);
        while (!test.get() && System.nanoTime() < until) Thread.sleep(5);
        check(test.get(), message);
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private interface Checked { void run() throws Exception; }
    private interface Check { boolean get() throws Exception; }
}
