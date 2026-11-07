package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.TimeUnit;

/**
 * py 源的子进程运行时：一个脚本一个 CPython 进程，行式 JSON-RPC 通信。
 *
 * <h3>为什么是子进程</h3>
 * 与 {@code NativeProvisioner} 拉起 unidbg 同构：解释器与 site-packages 体积不小，
 * 不进 fat jar，放 {@code dist/pyruntime} 同级；脚本会起本地 server、会死循环，
 * 进程隔离能把故障挡在 companion 之外。
 *
 * <h3>解释器与脚本目录的定位顺序</h3>
 * <pre>
 *   python：-Dxiugou.python=... → dist/pyruntime/{python.exe,python3,python} → PATH 上的 python
 *   pyshell：dist/pyshell → 开发回退到仓库内 companion/pyshell
 * </pre>
 *
 * <h3>与 JS 引擎的差别</h3>
 * JS 是进程内引擎（{@code JavaScriptSpider}），py 必须跨进程；所以这里的每次
 * {@link #callJson} 都是一次同步往返，超时或子进程死亡都会被直接观察到。
 */
public final class PyRuntime implements AutoCloseable {

    /** 单次方法调用超时：首调可能要下载/建连，留足余量。 */
    private static final long CALL_TIMEOUT_MS = 90_000L;

    /** 下载脚本的超时。 */
    private static final int SCRIPT_TIMEOUT_MS = 30_000;

    private static final String UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Edg/148.0.0.0";

    private final Process process;
    private final BufferedWriter stdin;
    private final BufferedReader stdout;
    private final ExecutorService reader = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "py-runtime-reader");
        t.setDaemon(true);
        return t;
    });
    private final AtomicLong nextId = new AtomicLong(1);
    private final AtomicBoolean terminated = new AtomicBoolean();
    private final Object writeLock = new Object();
    private final CompletableFuture<Map<String, Object>> ready = new CompletableFuture<>();
    private final ConcurrentHashMap<Long, CompletableFuture<Map<String, Object>>> pending = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, DanmakuSession> subscriptions = new ConcurrentHashMap<>();
    private volatile boolean closed;
    private final java.util.concurrent.locks.ReentrantLock protocolLock = new java.util.concurrent.locks.ReentrantLock();
    private volatile StreamRead readingStream;

    private static final class StreamRead {
        final String handle;
        final CompletableFuture<Map<String, Object>> response = new CompletableFuture<>();

        StreamRead(String handle) { this.handle = handle; }
    }
    /** load 阶段脚本自报的方法表，用于判断可选方法是否存在。 */
    private Map<String, Object> loadInfo;

    private PyRuntime(Process process) {
        this.process = process;
        this.stdin = new BufferedWriter(new OutputStreamWriter(
                process.getOutputStream(), StandardCharsets.UTF_8));
        this.stdout = new BufferedReader(new InputStreamReader(
                process.getInputStream(), StandardCharsets.UTF_8));
        reader.execute(this::pump);
    }

    // ------------------------------------------------------------------ 启动

    /**
     * 拉起子进程并加载脚本。
     *
     * @param scriptFile 已落盘的 .py
     * @param ext        脚本 init 参数
     * @param logFile    子进程 stderr 落盘位置
     */
    public static PyRuntime start(File scriptFile, String ext, File logFile) throws Exception {
        return start(scriptFile, ext, logFile, "", scriptFile.toURI().toString(), "");
    }

    public static PyRuntime start(File scriptFile, String ext, File logFile,
                                  String siteKey, String originalApi, String scriptProxyBase) throws Exception {
        return start(scriptFile, ext, logFile, siteKey, originalApi, scriptProxyBase, "");
    }

    public static PyRuntime start(File scriptFile, String ext, File logFile, String siteKey,
                                  String originalApi, String scriptProxyBase, String danmakuBase) throws Exception {
        File shell = shellDir();
        File runner = new File(shell, "runner.py");
        if (!runner.isFile()) {
            throw new IllegalStateException("找不到 pyshell/runner.py: " + runner.getAbsolutePath());
        }

        List<String> cmd = new ArrayList<>();
        cmd.add(pythonBinary());
        cmd.add("-X");
        cmd.add("utf8");
        cmd.add("-u");
        cmd.add(runner.getAbsolutePath());

        ProcessBuilder pb = new ProcessBuilder(cmd);
        File parent = logFile.getParentFile();
        if (parent != null) parent.mkdirs();
        pb.directory(shell);
        System.out.println("[PyRuntime] python=" + cmd.get(0)
                + "  pyshell=" + shell.getAbsolutePath());
        // stdout 是协议流，绝不能重定向；stderr 落盘便于排障
        pb.redirectErrorStream(false);
        pb.redirectError(ProcessBuilder.Redirect.appendTo(logFile));
        Map<String, String> env = pb.environment();
        env.put("PYTHONIOENCODING", "utf-8");
        env.put("PYTHONUTF8", "1");
        env.put("PYTHONDONTWRITEBYTECODE", "1");
        env.put("XIUGOU_SCRIPT_SITE_KEY", siteKey == null ? "" : siteKey);
        env.put("XIUGOU_SCRIPT_API", originalApi == null ? "" : originalApi);
        env.put("XIUGOU_SCRIPT_BASE", sourceBase(originalApi));
        env.put("XIUGOU_SCRIPT_ENTRY", scriptEntry(originalApi, scriptFile));
        env.put("XIUGOU_SCRIPT_PROXY_BASE", scriptProxyBase == null ? "" : scriptProxyBase);
        env.put("XIUGOU_SCRIPT_DANMAKU_BASE", danmakuBase == null ? "" : danmakuBase);
        boolean windows = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");
        env.put("XIUGOU_JAVA_BIN", new File(System.getProperty("java.home"),
                windows ? "bin/java.exe" : "bin/java").getAbsolutePath());
        List<String> classpath = new ArrayList<>();
        for (String entry : System.getProperty("java.class.path", "").split(java.util.regex.Pattern.quote(File.pathSeparator))) {
            classpath.add(new File(entry).getAbsolutePath());
        }
        env.put("XIUGOU_JAVA_CLASSPATH", String.join(File.pathSeparator, classpath));
        File home = new File(System.getProperty("user.home", ""));
        if (home.isAbsolute()) {
            env.put("XIUGOU_CACHE_DIR", new File(home, ".xiugou_tv_companion/py-cache").getAbsolutePath());
            env.put("XIUGOU_LOCAL_DIR", new File(home, ".xiugou_tv_companion/py-local").getAbsolutePath());
            env.put("XIUGOU_NET_CACHE_DIR", new File(home, ".xiugou_tv_companion/py-net-cache").getAbsolutePath());
        } else {
            env.remove("XIUGOU_CACHE_DIR");
            env.remove("XIUGOU_LOCAL_DIR");
            env.remove("XIUGOU_NET_CACHE_DIR");
        }
        String cacheId = scriptFile.getCanonicalPath();
        if (System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")) {
            cacheId = cacheId.toLowerCase(Locale.ROOT);
        }
        String proxy = System.getProperty("xiugou.proxy.base", "");
        if (!proxy.isEmpty()) env.put("XIUGOU_PROXY_BASE", proxy);

        PyRuntime rt = new PyRuntime(pb.start());
        rt.protocolLock.lock();
        try {
            Map<String, Object> ready = rt.awaitResponse(rt.ready, CALL_TIMEOUT_MS);
            if (!"ready".equals(ready.get("type"))) {
                throw new IllegalStateException("runner 未就绪: " + ready);
            }
            Map<String, Object> req = new LinkedHashMap<>();
            req.put("id", rt.nextId.getAndIncrement());
            req.put("action", "load");
            req.put("api", scriptFile.getAbsolutePath());
            req.put("ext", ext == null ? "" : ext);
            req.put("cacheId", cacheId);
            Map<String, Object> resp = rt.request(req);
            if (!"result".equals(resp.get("type"))) {
                throw new IllegalStateException("脚本加载失败: " + resp.get("error"));
            }
            Object value = resp.get("value");
            rt.loadInfo = value instanceof Map ? castMap(value) : new LinkedHashMap<>();
            return rt;
        } catch (Throwable t) {
            rt.close();
            throw t instanceof Exception ? (Exception) t : new Exception(t);
        } finally {
            rt.protocolLock.unlock();
        }
    }

    /** 解释器：显式指定 → 随包分发的便携运行时 → PATH。 */
    private static String pythonBinary() {
        String override = System.getProperty("xiugou.python");
        if (override != null && !override.trim().isEmpty()) return override.trim();

        File runtime = new File(distDir(), "pyruntime");
        String[] names = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")
                ? new String[]{"python.exe"}
                : new String[]{"bin/python3", "bin/python", "python3", "python"};
        for (String n : names) {
            File f = new File(runtime, n);
            if (f.isFile()) return f.getAbsolutePath();
        }
        return "python";
    }

    /** pyshell 目录：优先随包的 dist/pyshell，开发期回退到仓库内。 */
    static File shellDir() {
        File packaged = new File(distDir(), "pyshell");
        if (new File(packaged, "runner.py").isFile()) return packaged;
        File dev = new File("companion/pyshell");
        if (new File(dev, "runner.py").isFile()) return dev;
        return packaged;
    }

    private static File distDir() {
        File self = selfClasspath();
        if (self != null) return self.isDirectory() ? self : self.getParentFile();
        return new File(".").getAbsoluteFile();
    }

    private static File selfClasspath() {
        try {
            return new File(PyRuntime.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
        } catch (Throwable t) {
            return null;
        }
    }

    // ------------------------------------------------------------------ 调用

    /**
     * 调用脚本方法，返回 CatVod 契约要求的 **JSON 文本**。
     *
     * @return 序列化后的结果；脚本返回 None 时返回 null
     */
    public String callJson(String method, List<Object> args) throws Exception {
        protocolLock.lockInterruptibly();
        try {
            return callLocked(method, args);
        } finally {
            protocolLock.unlock();
        }
    }

    private String callLocked(String method, List<Object> args) throws Exception {
        if (closed) throw new IllegalStateException("py 运行时已关闭");
        Map<String, Object> req = new LinkedHashMap<>();
        req.put("id", nextId.getAndIncrement());
        req.put("action", "call");
        req.put("method", method);
        req.put("args", args == null ? new ArrayList<>() : args);

        Map<String, Object> resp = request(req);
        if ("error".equals(resp.get("type"))) {
            String err = String.valueOf(resp.get("error"));
            String trace = String.valueOf(resp.get("trace"));
            throw new IllegalStateException(method + " 失败: " + err
                    + (trace.isEmpty() ? "" : "\n" + tail(trace, 600)));
        }
        Object value = resp.get("value");
        return value == null ? null : JsonCodec.stringify(value);
    }

    /**
     * 一次请求往返。任何「这条通道已不可用」的情况都必须 {@link #close()}：
     * 子进程已退出（读到 EOF → ExecutionException）、看门狗中断、写管道失败、超时。
     * 否则 closed 仍为 false，读线程与进程句柄残留，之后每次调用都往死管道里写。
     */
    private Map<String, Object> request(Map<String, Object> req) throws Exception {
        return request(req, CALL_TIMEOUT_MS);
    }

    private Map<String, Object> request(Map<String, Object> req, long timeoutMs) throws Exception {
        return awaitResponse(send(req), timeoutMs);
    }

    private CompletableFuture<Map<String, Object>> send(Map<String, Object> req) throws Exception {
        long id = ((Number) req.get("id")).longValue();
        CompletableFuture<Map<String, Object>> response = new CompletableFuture<>();
        synchronized (writeLock) {
            if (closed) throw new IllegalStateException("py 运行时已关闭");
            pending.put(id, response);
            try {
                stdin.write(JsonCodec.stringify(req));
                stdin.write("\n");
                stdin.flush();
            } catch (java.io.IOException error) {
                pending.remove(id);
                close();
                throw new IllegalStateException("py 子进程已退出（写入失败）", error);
            }
        }
        return response;
    }

    private Map<String, Object> awaitResponse(CompletableFuture<Map<String, Object>> f, long timeoutMs) throws Exception {
        try {
            return f.get(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (java.util.concurrent.TimeoutException te) {
            f.cancel(true);
            close();
            throw new IllegalStateException("py 调用超时（" + timeoutMs + "ms）");
        } catch (java.util.concurrent.ExecutionException ee) {
            close();
            Throwable cause = ee.getCause() == null ? ee : ee.getCause();
            throw cause instanceof Exception ? (Exception) cause : new IllegalStateException(cause);
        } catch (InterruptedException ie) {
            // 普通脚本调用没有按请求取消入口，必须结束其原 child。
            f.cancel(true);
            close();
            Thread.currentThread().interrupt();
            throw ie;
        }
    }

    byte[] readStream(String handle, int size) throws java.io.IOException {
        long timeout = Math.max(1L, Math.min(30_000L, Long.getLong("xiugou.py.streamReadTimeoutMs", 30_000L)));
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeout);
        boolean locked = false;
        try {
            locked = protocolLock.tryLock(timeout, TimeUnit.MILLISECONDS);
            if (!locked || !isAlive()) throw new java.io.IOException("script stream unavailable");
            StreamRead operation = new StreamRead(handle);
            readingStream = operation;
            Map<String, Object> req = new LinkedHashMap<>();
            req.put("id", nextId.getAndIncrement()); req.put("action", "streamRead");
            req.put("streamId", handle); req.put("size", size);
            send(req).whenComplete((response, failure) -> {
                if (failure == null) operation.response.complete(response);
                else operation.response.completeExceptionally(failure);
            });
            long remaining = Math.max(1L, TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()));
            Map<String, Object> response = operation.response.get(remaining, TimeUnit.MILLISECONDS);
            if (!"result".equals(response.get("type"))) throw new java.io.IOException("script stream failed");
            Object value = response.get("value");
            if (!(value instanceof Map)) throw new IllegalArgumentException();
            Map<?, ?> chunk = (Map<?, ?>) value;
            Object encoded = chunk.get("dataBase64"), eof = chunk.get("eof");
            if (!(encoded instanceof String) || ((String) encoded).length() > 4 * ((size + 2) / 3)
                    || !(eof instanceof Boolean)) throw new IllegalArgumentException();
            byte[] data = java.util.Base64.getDecoder().decode((String) encoded);
            if (data.length > size || (Boolean) eof && data.length != 0
                    || !(Boolean) eof && data.length == 0) throw new IllegalArgumentException();
            return (Boolean) eof ? null : data;
        } catch (InterruptedException interrupted) {
            closeStream(handle);
            Thread.currentThread().interrupt();
            throw new java.io.IOException("script stream interrupted");
        } catch (java.util.concurrent.TimeoutException timeoutError) {
            closeStream(handle);
            throw new java.io.IOException("script stream timeout");
        } catch (java.io.IOException error) {
            throw error;
        } catch (Exception error) {
            close();
            throw new java.io.IOException("script stream failed");
        } finally {
            if (locked) {
                readingStream = null;
                protocolLock.unlock();
            }
        }
    }

    void closeStream(String handle) {
        if (!isAlive()) return;
        boolean interrupted = Thread.interrupted();
        StreamRead operation = readingStream;
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(1500L);
        try {
            Map<String, Object> req = new LinkedHashMap<>();
            req.put("id", nextId.getAndIncrement()); req.put("action", "streamClose"); req.put("streamId", handle);
            if (!"result".equals(request(req, 1500L).get("type"))) {
                close();
                return;
            }
            if (operation != null && handle.equals(operation.handle)) {
                long remaining = Math.max(1L, TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()));
                operation.response.get(remaining, TimeUnit.MILLISECONDS);
            }
        } catch (Exception error) {
            if (error instanceof InterruptedException) interrupted = true;
            close();
        } finally {
            if (interrupted) Thread.currentThread().interrupt();
        }
    }

    /** 通道是否仍可用（未关闭且子进程存活）。 */
    public boolean isAlive() {
        return !closed && process.isAlive();
    }

    private void pump() {
        try {
            while (!closed) {
                String line = stdout.readLine();
                if (line == null) throw new IllegalStateException("py 子进程已退出（stdout EOF）");
                Map<String, Object> frame = JsonCodec.parseObject(line);
                String type = String.valueOf(frame.get("type"));
                if ("ping".equals(type)) continue;
                if ("ready".equals(type)) { ready.complete(frame); continue; }
                if ("event".equals(type)) {
                    if (line.getBytes(StandardCharsets.UTF_8).length > 16 * 1024
                            || !"danmaku".equals(frame.get("topic"))) continue;
                    DanmakuSession owner = subscriptions.get(String.valueOf(frame.get("subscriptionId")));
                    if (owner != null) owner.emit(frame);
                    continue;
                }
                if (!("result".equals(type) || "error".equals(type)) || !(frame.get("id") instanceof Long))
                    throw new IllegalStateException("invalid python response");
                CompletableFuture<Map<String, Object>> response = pending.remove((Long) frame.get("id"));
                if (response == null) throw new IllegalStateException("unexpected python response id");
                response.complete(frame);
            }
        } catch (Exception failure) {
            // All waiter and subscription lifetimes end with this exact pipe, including idle EOF.
            close();
        }
    }

    public interface DanmakuListener {
        void event(long sequence, Map<String, Object> item);
        void closed();
    }

    public DanmakuSession openDanmaku(String id, DanmakuListener listener, Runnable release) {
        if (!id.matches("[0-9a-f]{32}") || !hasMethod("danmaku"))
            throw new IllegalStateException("script danmaku unavailable");
        String generation = String.valueOf(loadInfo.get("generation"));
        if (!generation.matches("[0-9a-f]{32}")) throw new IllegalStateException("invalid python generation");
        DanmakuSession session = new DanmakuSession(id, generation, listener, release);
        if (subscriptions.putIfAbsent(id, session) != null) throw new IllegalStateException("duplicate subscription");
        if (closed) session.finish();
        return session;
    }

    /** A subscription owns the original pipe and never reacquires a replacement child. */
    public final class DanmakuSession implements AutoCloseable {
        private final String id;
        public final String generation;
        private final DanmakuListener listener;
        private final Runnable release;
        private final Object lifecycle = new Object();
        private final AtomicBoolean ended = new AtomicBoolean();
        private final AtomicBoolean released = new AtomicBoolean();
        private boolean startSent;
        private boolean startFinished = true;
        private boolean stopFinished;
        private long lastSequence;

        private DanmakuSession(String id, String generation, DanmakuListener listener, Runnable release) {
            this.id = id; this.generation = generation; this.listener = listener; this.release = release;
        }

        public boolean isClosed() { return ended.get(); }

        public void start(String room) throws Exception {
            protocolLock.lockInterruptibly();
            try {
                CompletableFuture<Map<String, Object>> response;
                synchronized (lifecycle) {
                    if (ended.get()) return;
                    Map<String, Object> req = command("danmakuStart");
                    req.put("roomId", room);
                    if (startSent) throw new IllegalStateException("subscription already started");
                    response = send(req);
                    startSent = true;
                    startFinished = false;
                }
                Map<String, Object> result = awaitResponse(response, 30_000L);
                if (!"result".equals(result.get("type"))) {
                    PyRuntime.this.close();
                    throw new IllegalStateException("script danmaku failed");
                }
            } catch (Exception error) {
                close();
                throw error;
            } finally {
                synchronized (lifecycle) { startFinished = true; }
                releaseIfFinished();
                protocolLock.unlock();
            }
        }

        private Map<String, Object> command(String action) {
            Map<String, Object> req = new LinkedHashMap<>();
            req.put("id", nextId.getAndIncrement()); req.put("action", action);
            req.put("subscriptionId", id); req.put("generation", generation);
            return req;
        }

        private void emit(Map<String, Object> frame) {
            if (ended.get() || !generation.equals(frame.get("generation")) || !(frame.get("seq") instanceof Long)
                    || !(frame.get("item") instanceof Map)) return;
            long sequence = (Long) frame.get("seq");
            if (sequence <= lastSequence) return;
            Map<String, Object> item = validateDanmakuItem(castMap(frame.get("item")));
            if (item == null) return;
            lastSequence = sequence;
            if (!ended.get()) listener.event(sequence, item);
        }

        private boolean retire() {
            if (!ended.compareAndSet(false, true)) return false;
            subscriptions.remove(id, this);
            listener.closed();
            return true;
        }

        private void release() {
            if (released.compareAndSet(false, true)) release.run();
        }

        private void releaseIfFinished() {
            synchronized (lifecycle) {
                if (ended.get() && startFinished && stopFinished) release();
            }
        }

        private void finish() {
            try { retire(); } finally { release(); }
        }

        @Override public void close() {
            if (!retire()) return;
            boolean interrupted = Thread.interrupted();
            try {
                boolean sent;
                synchronized (lifecycle) { sent = startSent; }
                if (!sent || !isAlive()) return;
                // This control RPC deliberately bypasses a blocked normal call/stream chunk.
                if (!"result".equals(request(command("danmakuStop"), 3000L).get("type"))) PyRuntime.this.close();
            } catch (Exception error) {
                if (error instanceof InterruptedException) interrupted = true;
                PyRuntime.this.close();
            } finally {
                synchronized (lifecycle) { stopFinished = true; }
                releaseIfFinished();
                if (interrupted) Thread.currentThread().interrupt();
            }
        }
    }

    private static Map<String, Object> validateDanmakuItem(Map<String, Object> item) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (item.containsKey("state")) {
            Object state = item.get("state"), message = item.get("msg");
            if (!("ready".equals(state) || "retrying".equals(state) || "error".equals(state))
                    || message != null && (!(message instanceof String) || ((String) message).length() > 512)) return null;
            result.put("state", state);
            if (message != null) result.put("msg", message);
        } else {
            Object text = item.get("text"), color = item.get("color");
            if (!(text instanceof String) || ((String) text).isEmpty() || !rgb(color)) return null;
            result.put("text", text); result.put("color", color);
            if (item.containsKey("colors")) {
                Object colors = item.get("colors");
                if (!(colors instanceof List) || ((List<?>) colors).isEmpty() || ((List<?>) colors).size() > 8) return null;
                for (Object value : (List<?>) colors) if (!rgb(value)) return null;
                result.put("colors", new ArrayList<>((List<?>) colors));
            }
        }
        return java.util.Collections.unmodifiableMap(result);
    }

    private static boolean rgb(Object value) {
        return value instanceof Long && (Long) value >= 0 && (Long) value <= 0xffffff;
    }

    private static String tail(String s, int n) {
        return s.length() <= n ? s : s.substring(s.length() - n);
    }

    /** 脚本是否声明了该方法（决定可选方法返回 null 还是真的去调用）。 */
    public boolean hasMethod(String method) {
        if (loadInfo == null) return false;
        Object methods = loadInfo.get("methods");
        if (!(methods instanceof List)) return true; // 拿不到方法表时不拦截，交给脚本自己报错
        for (Object m : (List<?>) methods) {
            if (method.equals(String.valueOf(m))) return true;
        }
        return false;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> castMap(Object o) {
        return (Map<String, Object>) o;
    }

    @Override
    public void close() {
        if (!terminated.compareAndSet(false, true)) return;
        closed = true;
        IllegalStateException failure = new IllegalStateException("python runtime closed");
        ready.completeExceptionally(failure);
        for (CompletableFuture<Map<String, Object>> response : pending.values()) response.completeExceptionally(failure);
        pending.clear();
        for (DanmakuSession subscription : subscriptions.values()) subscription.finish();
        // Only an idle protocol may run cleanup; an interrupted request has no safe reply boundary.
        boolean idle = !protocolLock.isHeldByCurrentThread() && protocolLock.tryLock();
        try {
            if (idle && !Thread.currentThread().isInterrupted()) {
                try {
                    synchronized (writeLock) {
                        stdin.write("{\"action\":\"exit\"}\n");
                        stdin.flush();
                    }
                    process.waitFor(300, TimeUnit.MILLISECONDS);
                } catch (Exception ignored) {
                    if (ignored instanceof InterruptedException) Thread.currentThread().interrupt();
                }
            }
        } finally {
            if (idle) protocolLock.unlock();
            if (process.isAlive()) process.destroyForcibly();
            reader.shutdownNow();
        }
    }

    // ------------------------------------------------------------------ 脚本获取

    /**
     * 把 api 变成本地可执行脚本，必要时下载并缓存。
     *
     * <p><b>blob → raw 归一</b>：配置里的 api 普遍写的是 GitHub 的 blob 页面
     * （返回 HTML 而不是源码），必须换成 raw 才能执行。
     */
    static String sourceBase(String api) {
        if (api == null || api.isEmpty()) return "";
        if (api.matches("(?i)^(https?|file):.*")) {
            String clean = api.split("[?#]", 2)[0];
            int slash = clean.lastIndexOf('/');
            return slash < 0 ? "" : clean.substring(0, slash + 1);
        }
        return new File(api).getAbsoluteFile().toPath().getParent().toUri().toString();
    }

    private static String scriptEntry(String api, File fallback) {
        if (api == null || api.isEmpty()) {
            if (fallback == null) throw new IllegalArgumentException("空 api");
            return fallback.toPath().toAbsolutePath().normalize().toUri().toString();
        }
        String normalized = normalizeScriptUrl(api);
        if (normalized.matches("(?i)^https?://.*")) {
            String url = encodeUrl(normalized);
            URI parsed = URI.create(url);
            if (parsed.getRawAuthority() == null || parsed.getRawAuthority().isEmpty())
                throw new IllegalArgumentException("script URL unavailable");
            return url;
        }
        File local = api.regionMatches(true, 0, "file:", 0, 5) ? new File(URI.create(api)) : new File(api);
        return local.toPath().toAbsolutePath().normalize().toUri().toString();
    }

    public static File ensureScript(String api, File cacheDir) throws Exception {
        String url = scriptEntry(api, null);
        if (url.startsWith("file:")) {
            File local = new File(URI.create(url));
            if (!local.isFile()) throw new IllegalArgumentException("script file unavailable");
            return local;
        }
        File dir = new File(cacheDir, "py");
        dir.mkdirs();
        File target = new File(dir, md5(url) + ".py");
        if (target.isFile() && target.length() > 0) return target;

        File tmp = new File(dir, target.getName() + ".pending");
        HttpURLConnection conn = (HttpURLConnection) URI.create(url).toURL().openConnection();
        conn.setRequestProperty("User-Agent", UA);
        conn.setConnectTimeout(15_000);
        conn.setReadTimeout(SCRIPT_TIMEOUT_MS);
        conn.setInstanceFollowRedirects(true);
        try (InputStream in = conn.getInputStream()) {
            Files.copy(in, tmp.toPath(), StandardCopyOption.REPLACE_EXISTING);
        } finally {
            conn.disconnect();
        }
        if (!tmp.isFile() || tmp.length() == 0) {
            throw new IllegalStateException("脚本下载为空: " + url);
        }
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
        System.out.println("[PySpider] 脚本就绪: " + target.getName() + " (" + target.length() + " B)");
        return target;
    }

    /**
     * GitHub blob 页面 → raw 内容地址。其它形式原样返回。
     *
     * <pre>
     * https://gh-proxy.com/https://github.com/o/r/blob/main/a/b.py
     *   → https://gh-proxy.com/https://raw.githubusercontent.com/o/r/main/a/b.py
     * </pre>
     * 代理前缀会被保留，避免破坏需要借道的环境。
     */
    public static String normalizeScriptUrl(String api) {
        if (api == null) return "";
        String a = api.trim();
        if (a.isEmpty()) return "";
        int idx = a.indexOf("github.com/");
        if (idx < 0 || a.indexOf("/blob/", idx) < 0) return a;

        String prefix = a.substring(0, idx);
        String rest = a.substring(idx + "github.com/".length());
        int blob = rest.indexOf("/blob/");
        String ownerRepo = rest.substring(0, blob);
        String after = rest.substring(blob + "/blob/".length());
        return prefix + "raw.githubusercontent.com/" + ownerRepo + "/" + after;
    }

    /**
     * 非 ASCII 字符转 %XX，ASCII 原样保留（含 {@code %}，因此已编码的 %XX 不会被二次编码）。
     *
     * <p>实测配置里 147 个 api 有超过一半写的是**未编码的原始中文文件名**
     * （{@code .../py/黄果漫剧.py}）。浏览器会自动编码，{@code java.net.URI} 不会——
     * 直接把裸中文塞进 URL 会被代理/服务端以 400 拒绝。
     */
    static String encodeUrl(String url) {
        if (url == null || url.isEmpty()) return "";
        boolean ascii = true;
        for (int i = 0; i < url.length(); i++) {
            if (url.charAt(i) > 0x7F) {
                ascii = false;
                break;
            }
        }
        if (ascii) return url;

        StringBuilder sb = new StringBuilder(url.length() + 32);
        for (byte b : url.getBytes(StandardCharsets.UTF_8)) {
            int c = b & 0xFF;
            if (c < 0x80) {
                sb.append((char) c);
            } else {
                sb.append('%').append(Character.toUpperCase(Character.forDigit(c >> 4, 16)))
                        .append(Character.toUpperCase(Character.forDigit(c & 0xF, 16)));
            }
        }
        return sb.toString();
    }

    static String md5(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] d = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Throwable t) {
            return Integer.toHexString(s.hashCode());
        }
    }
}
