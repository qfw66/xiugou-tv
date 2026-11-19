package com.fongmi.companion;

import com.fongmi.companion.ipc.LineProcess;
import com.fongmi.companion.ui.UiBridge;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** One bounded Node process per checksum-pinned source, shared by its video sites. */
public final class CatNodeRuntime implements AutoCloseable {
    private static final Map<String, CatNodeRuntime> ACTIVE = new ConcurrentHashMap<>();
    private static final Object POOL_LOCK = new Object();
    private static volatile long epoch;
    static long epoch() { return epoch; }
    private static final int MAX_SOURCES = 4;
    private static final String READY_PREFIX = "XIUGOU_CAT ";
    private final File root;
    private final Source source;
    private final CompletableFuture<Void> ready = new CompletableFuture<>();
    private final AtomicBoolean starting = new AtomicBoolean();
    private final Object lifecycle = new Object();
    private final java.util.concurrent.locks.ReentrantReadWriteLock requests =
            new java.util.concurrent.locks.ReentrantReadWriteLock(true);
    private volatile LineProcess process;
    private volatile boolean closed;
    private int port;
    private int controlPort;

    static final class Source {
        final String url;
        final String md5;
        final String configMd5;
        final String route;
        final Object siteExt;

        Source(String url, String md5, String configMd5, String route, Object siteExt) throws IOException {
            try {
                URI uri = URI.create(url);
                if (!("https".equals(uri.getScheme()) || "http".equals(uri.getScheme()))
                        || uri.getHost() == null || uri.getUserInfo() != null || uri.getFragment() != null
                        || !uri.getPath().toLowerCase(Locale.ROOT).endsWith(".js.md5")) {
                    throw new IllegalArgumentException();
                }
            } catch (RuntimeException error) { throw new IOException("Invalid cat source URL"); }
            this.url = url;
            this.md5 = digest(md5);
            this.configMd5 = configMd5 == null ? null : digest(configMd5);
            this.route = route;
            this.siteExt = siteExt;
            if (route != null && !"@settings".equals(route) && !validRoute(route)) {
                throw new IOException("Invalid cat site route");
            }
        }

        static Source from(String ext) throws IOException {
            Map<String,Object> value = JsonCodec.parseObject(ext);
            return new Source(text(value.get("bundleUrl")), text(value.get("md5")),
                    text(value.get("configMd5")), text(value.get("route")), value.get("siteExt"));
        }

        Map<String,Object> descriptor(String route, Object ext) {
            Map<String,Object> value = new LinkedHashMap<>();
            value.put("bundleUrl", url); value.put("md5", md5); value.put("configMd5", configMd5);
            value.put("route", route);
            if (ext != null) value.put("siteExt", ext);
            return value;
        }

        URI scriptUri() { return sibling(url, false, false); }
        URI configUri() { return sibling(url, true, false); }
    }

    private CatNodeRuntime(Source source, File root) {
        this.source = source;
        this.root = root.getAbsoluteFile();
    }

    static CatNodeRuntime acquire(Source source, File root, long expectedEpoch) throws Exception {
        String key = root.getCanonicalPath() + "|" + source.url + "|" + source.md5 + "|" + source.configMd5;
        CatNodeRuntime runtime;
        synchronized (POOL_LOCK) {
            if (expectedEpoch != epoch) throw new IOException("Cat source generation expired");
            runtime = ACTIVE.get(key);
            if (runtime != null && (runtime.closed || (runtime.ready.isDone() && !runtime.isAlive()))) {
                runtime.close(); ACTIVE.remove(key); runtime = null;
            }
            if (runtime == null) {
                if (ACTIVE.size() >= MAX_SOURCES) throw new IOException("猫源运行数量已达上限，请切换配置后重试");
                runtime = new CatNodeRuntime(source, root);
                ACTIVE.put(key, runtime);
            }
        }
        try {
            runtime.initialize();
            return runtime;
        } catch (Exception error) {
            ACTIVE.remove(key, runtime); runtime.close(); throw error;
        }
    }

    public static void closeAll() {
        List<CatNodeRuntime> closing;
        synchronized (POOL_LOCK) { epoch++; closing = new ArrayList<>(ACTIVE.values()); ACTIVE.clear(); }
        closing.forEach(CatNodeRuntime::close);
    }

    public static String importConfig(String url, String md5, File root) throws Exception {
        long expectedEpoch = epoch;
        Source initial = new Source(url, md5, null, null, null);
        String configMd5 = digest(new String(download(sibling(url, true, true)), StandardCharsets.UTF_8));
        Source pinned = new Source(url, md5, configMd5, null, null);
        CatNodeRuntime runtime = acquire(pinned, root, expectedEpoch);
        try {
        Map<String,Object> config = JsonCodec.parseObject(runtime.request("/config", null));
        Object video = config.get("video");
        Object rawSites = video instanceof Map ? ((Map<?,?>)video).get("sites") : config.get("sites");
        if (!(rawSites instanceof List<?>)) throw new IOException("猫源没有返回视频站点清单");
        List<Map<String,Object>> sites = new ArrayList<>();
        String prefix = "cat_" + hash("SHA-256", initial.url.getBytes(StandardCharsets.UTF_8)).substring(0, 12) + "_";
        Map<String,Boolean> seen = new LinkedHashMap<>();
        for (Object raw : (List<?>)rawSites) {
            if (!(raw instanceof Map<?,?> item) || Boolean.FALSE.equals(item.get("enable"))) continue;
            String route = text(item.get("api"));
            if (!validRoute(route)) continue;
            String key = text(item.get("key"));
            if (key.isBlank()) key = hash("SHA-256", route.getBytes(StandardCharsets.UTF_8)).substring(0, 12);
            if (seen.put(key, true) != null) continue;
            Map<String,Object> site = new LinkedHashMap<>();
            site.put("key", prefix + key); site.put("name", text(item.get("name")));
            site.put("type", 3); site.put("api", "catnode");
            site.put("ext", pinned.descriptor(route, item.get("ext")));
            for (String field : List.of("searchable", "quickSearch", "filterable", "changeable", "categories", "style")) {
                if (item.containsKey(field)) site.put(field, item.get(field));
            }
            sites.add(site);
        }
        if (sites.isEmpty()) throw new IOException("猫源未返回可用的视频站点");
        sites.add(Map.of("key", prefix + "settings", "name", "猫源配置（本机网页）", "type", 3,
                "api", "catnode", "searchable", 0, "quickSearch", 0,
                "ext", pinned.descriptor("@settings", null)));
        return JsonCodec.stringify(Map.of("sites", sites));
        } catch (Exception error) {
            synchronized (POOL_LOCK) { ACTIVE.values().removeIf(value -> value == runtime); }
            runtime.close();
            throw error;
        }
    }

    private void initialize() throws Exception {
        if (starting.compareAndSet(false, true)) {
            try { boot(); ready.complete(null); }
            catch (Exception error) { ready.completeExceptionally(error); throw error; }
        }
        try { ready.get(90, TimeUnit.SECONDS); }
        catch (java.util.concurrent.ExecutionException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            throw new IOException("Cat source startup failed", error);
        }
        if (closed) throw new IOException("Cat source was stopped");
    }

    private void boot() throws Exception {
        String sourceId = hash("SHA-256", source.url.getBytes(StandardCharsets.UTF_8)).substring(0, 24);
        File directory = new File(root, sourceId);
        File version = new File(directory, "code/" + source.md5 + "-" + source.configMd5);
        File state = new File(directory, "state");
        Files.createDirectories(version.toPath());
        Files.createDirectories(state.toPath());
        File script = new File(version, "index.js");
        File config = new File(version, "index.config.js");
        ensureVerified(script, source.scriptUri(), source.md5);
        ensureVerified(config, source.configUri(), source.configMd5);
        File runner = new File(root, "runner.cjs");
        synchronized (POOL_LOCK) {
            try (InputStream in = CatNodeRuntime.class.getResourceAsStream("/catnode/runner.cjs")) {
                if (in == null) throw new IOException("Cat runtime resource missing");
                byte[] bytes = in.readAllBytes();
                if (!runner.isFile() || !java.util.Arrays.equals(Files.readAllBytes(runner.toPath()), bytes)) {
                    Files.createDirectories(root.toPath()); Files.write(runner.toPath(), bytes);
                }
            }
        }
        List<String> command = new ArrayList<>(List.of(nodeExecutable(), "--max-old-space-size=256", "--permission",
                "--allow-fs-read=" + runner.getAbsolutePath(), "--allow-fs-read=" + directory.getAbsolutePath(),
                "--allow-fs-write=" + state.getAbsolutePath(), runner.getAbsolutePath()));
        ProcessBuilder builder = new ProcessBuilder(command).directory(state);
        Map<String,String> env = builder.environment();
        env.remove("NODE_OPTIONS"); env.remove("NODE_V8_COVERAGE");
        for (String variable : List.of("APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TMP", "TEMP")) {
            File isolated = new File(state, variable.toLowerCase(Locale.ROOT));
            Files.createDirectories(isolated.toPath()); env.put(variable, isolated.getAbsolutePath());
        }
        env.put("NODE_PATH", state.getAbsolutePath());
        builder.redirectError(ProcessBuilder.Redirect.DISCARD);
        synchronized (lifecycle) {
            if (closed || Thread.currentThread().isInterrupted()) throw new IOException("Cat source load cancelled");
            process = LineProcess.start(builder, "cat-node");
        }
        process.send(JsonCodec.stringify(Map.of("bundle", script.getAbsolutePath(),
                "config", config.getAbsolutePath(), "state", state.getAbsolutePath())));
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60);
        while (!closed && System.nanoTime() < deadline) {
            String line = process.readLine(1000);
            if (line == null) {
                if (!process.isAlive()) throw new IOException("猫源Node进程启动失败（需要Node 22+），请检查运行时");
                continue;
            }
            if (!line.startsWith(READY_PREFIX)) continue;
            Map<String,Object> frame = JsonCodec.parseObject(line.substring(READY_PREFIX.length()));
            if ("error".equals(frame.get("type"))) throw new IOException("猫源加载失败：" + frame.get("error"));
            if (!"ready".equals(frame.get("type"))) continue;
            port = port(frame.get("port")); controlPort = port(frame.get("controlPort"));
            return;
        }
        throw new IOException("猫源启动超时或已取消");
    }

    int port() { return port; }
    String configUrl() { return "http://127.0.0.1:" + controlPort + "/config"; }
    boolean isAlive() { return !closed && process != null && process.isAlive(); }
    java.util.concurrent.locks.Lock readLease() { return requests.readLock(); }

    CatNodeRuntime refreshed(long expectedEpoch) throws Exception {
        Map<String,Object> state;
        requests.readLock().lockInterruptibly();
        try {
            if (!isAlive()) return acquire(source, root, expectedEpoch);
            state = JsonCodec.parseObject(requestAt(controlPort, "/configuration-state", null));
        } finally { requests.readLock().unlock(); }
        if (!"restart".equals(state.get("reload")) || !(state.get("generation") instanceof Number generation)
                || generation.longValue() == 0) return this;
        requests.writeLock().lockInterruptibly();
        try {
            // A source may retain module-level address caches even after /init.
            // Drain content calls, then replace only this bundle. Other sources keep running.
            if (isAlive()) {
                synchronized (POOL_LOCK) {
                    close();
                    ACTIVE.values().removeIf(value -> value == this);
                }
            }
            return acquire(source, root, expectedEpoch);
        } finally { requests.writeLock().unlock(); }
    }


    String siteRevision(String route) throws Exception {
        if (!validRoute(route)) throw new IOException("Invalid cat site route");
        String query = "/site-revision?route=" + java.net.URLEncoder.encode(route, StandardCharsets.UTF_8);
        Object revision = JsonCodec.parseObject(requestAt(controlPort, query, null)).get("revision");
        if (!(revision instanceof String value) || !value.matches("[0-9]+:[0-9]+")) {
            throw new IOException("Invalid cat site revision");
        }
        return value;
    }

    String request(String route, Map<String,Object> body) throws Exception {
        java.util.concurrent.locks.Lock lease = readLease();
        lease.lockInterruptibly();
        try { return requestWithEvents(route, body); }
        finally { lease.unlock(); }
    }

    private String requestWithEvents(String route, Map<String,Object> body) throws Exception {
        String requestId = java.util.UUID.randomUUID().toString();
        String result;
        String web;
        try { result = requestAt(port, route, body, requestId); }
        finally { web = drainEvents(requestId); }
        if (web != null && route.endsWith("/detail")) {
            return JsonCodec.stringify(Map.of("list", List.of(Map.of("vod_id", "cat-web-configuration",
                    "vod_name", "网页配置", "vod_pic", "", "vod_content",
                    "在本机浏览器打开配置页，保存后返回应用刷新站点。\n" + web))));
        }
        if (web != null && route.endsWith("/action")) return JsonCodec.stringify(Map.of("type", "web", "url", web));
        return result;
    }

    private String requestAt(int destination, String route, Map<String,Object> body) throws Exception {
        return requestAt(destination, route, body, null);
    }

    private String requestAt(int destination, String route, Map<String,Object> body, String requestId) throws Exception {
        if (!isAlive()) throw new IOException("猫源服务已停止，请重新打开站点");
        if (!route.startsWith("/") || route.startsWith("//") || route.contains("..") || route.contains("\\")) {
            throw new IOException("Invalid cat request path");
        }
        URI target = URI.create("http://127.0.0.1:" + destination + route);
        HttpURLConnection connection = (HttpURLConnection) URI.create(target.toASCIIString())
                .toURL().openConnection(Proxy.NO_PROXY);
        connection.setConnectTimeout(3000); connection.setReadTimeout(destination == controlPort ? 1500 : 45_000);
        connection.setInstanceFollowRedirects(false);
        if (requestId != null) connection.setRequestProperty("X-Xiugou-Request", requestId);
        try {
            if (body != null) {
                byte[] bytes = JsonCodec.stringify(body).getBytes(StandardCharsets.UTF_8);
                connection.setRequestMethod("POST"); connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                connection.setFixedLengthStreamingMode(bytes.length);
                try (var out = connection.getOutputStream()) { out.write(bytes); }
            }
            int status = connection.getResponseCode();
            if (status != 200) {
                Map<String,Object> errorBody = Map.of();
                try (InputStream in = connection.getErrorStream()) {
                    if (in != null) errorBody = JsonCodec.parseObject(new String(HttpBridge.readCapped(in), StandardCharsets.UTF_8));
                } catch (Exception ignored) { /* Raw bodies never cross the diagnostic boundary. */ }
                throw new CatNodeHttpException(status, route, errorBody);
            }
            try (InputStream in = connection.getInputStream()) {
                String result = new String(HttpBridge.readCapped(in), StandardCharsets.UTF_8);
                return result.replace("js2p://_WEB_", "http://127.0.0.1:" + port);
            }
        } finally { connection.disconnect(); }
    }

    private String drainEvents(String requestId) {
        String web = null;
        try {
            HttpURLConnection connection = (HttpURLConnection) URI.create("http://127.0.0.1:" + controlPort + "/events?requestId=" + requestId)
                    .toURL().openConnection(Proxy.NO_PROXY);
            connection.setConnectTimeout(500); connection.setReadTimeout(500);
            try (InputStream in = connection.getInputStream()) {
                Object value = JsonCodec.parse(new String(HttpBridge.readCapped(in), StandardCharsets.UTF_8));
                if (value instanceof List<?> events) for (Object raw : events) {
                    if (!(raw instanceof Map<?,?> event)) continue;
                    if ("toast".equals(event.get("type"))) UiBridge.get().onToast(text(event.get("text")));
                    if ("openWeb".equals(event.get("type"))) {
                        URI target = URI.create(text(event.get("url")));
                        if (("http".equals(target.getScheme()) || "https".equals(target.getScheme()))
                                && target.getHost() != null && target.getUserInfo() == null) {
                            web = "127.0.0.1".equals(target.getHost()) && target.getPort() == port
                                    && target.getPath().startsWith("/website") ? configUrl() : target.toASCIIString();
                        }
                    }
                }
            } finally { connection.disconnect(); }
        } catch (Exception ignored) { /* Optional UI feedback must not replace the site response. */ }
        return web;
    }

    @Override public void close() {
        LineProcess child;
        synchronized (lifecycle) { closed = true; child = process; }
        ready.completeExceptionally(new IOException("Cat source stopped"));
        if (child != null) {
            try {
                child.send("stop");
                long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(1000);
                boolean stopped = false, failed = false;
                while (System.nanoTime() < until) {
                    String line = child.readLine(20);
                    if (line != null && line.startsWith(READY_PREFIX)) {
                        Map<String,Object> status = JsonCodec.parseObject(line.substring(READY_PREFIX.length()));
                        if ("error".equals(status.get("type"))) failed = true;
                        if ("stopped".equals(status.get("type"))) { stopped = true; break; }
                    }
                    if (line == null && !child.isAlive()) break;
                }
                if (!stopped || failed) System.err.println("[CatNode] Final shutdown/profile synchronization was not confirmed");
            } catch (Exception ignored) {
                if (ignored instanceof InterruptedException) Thread.currentThread().interrupt();
            } finally { child.close(); }
        }
    }

    private static String nodeExecutable() throws Exception {
        String explicit = System.getProperty("xiugou.node", "");
        if (!explicit.isBlank()) return explicit;
        File own = new File(CatNodeRuntime.class.getProtectionDomain().getCodeSource().getLocation().toURI());
        String name = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win") ? "node.exe" : "node";
        for (File candidate : List.of(new File(own.getParentFile(), "noderuntime/" + name),
                new File("companion/noderuntime/" + name))) {
            if (candidate.isFile()) return candidate.getAbsolutePath();
        }
        String path = System.getenv("PATH");
        for (String entry : (path == null ? "" : path).split(java.util.regex.Pattern.quote(File.pathSeparator))) {
            File candidate = new File(entry, name);
            if (candidate.isFile()) return candidate.getAbsolutePath();
        }
        throw new IOException("缺少猫源Node运行时，请使用包含noderuntime的完整程序目录");
    }

    private static void ensureVerified(File file, URI uri, String expected) throws Exception {
        if (expected == null) throw new IOException("Cat config MD5 missing");
        if (file.isFile() && file.length() <= HttpBridge.MAX_BODY_BYTES
                && hash("MD5", Files.readAllBytes(file.toPath())).equals(expected)) return;
        byte[] bytes = download(uri);
        if (!hash("MD5", bytes).equals(expected)) throw new IOException("猫源 MD5 校验失败：" + uri.getHost());
        File pending = new File(file.getParentFile(), file.getName() + ".tmp");
        Files.write(pending.toPath(), bytes);
        Files.move(pending.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING);
    }

    private static byte[] download(URI uri) throws Exception {
        Exception last = null;
        List<URI> candidates = new ArrayList<>(); candidates.add(uri);
        String mirror = XptvSpider.jsDelivrMirror(uri.toString());
        if (mirror != null) candidates.add(URI.create(mirror));
        for (URI candidate : candidates) {
            List<Proxy> proxies = new ArrayList<>(); proxies.add(Proxy.NO_PROXY);
            if (ProxySelector.getDefault() != null) for (Proxy proxy : ProxySelector.getDefault().select(candidate)) {
                if (!proxies.contains(proxy)) proxies.add(proxy);
            }
            for (Proxy proxy : proxies) {
                if (Thread.currentThread().isInterrupted()) throw new InterruptedException("Cat download cancelled");
                HttpURLConnection connection = (HttpURLConnection) candidate.toURL().openConnection(proxy);
                connection.setConnectTimeout(15_000); connection.setReadTimeout(20_000);
                connection.setRequestProperty("User-Agent", "okhttp/5.5.0");
                try {
                    if (connection.getResponseCode() != 200) throw new IOException("猫源下载 HTTP " + connection.getResponseCode());
                    try (InputStream in = connection.getInputStream()) { return HttpBridge.readCapped(in); }
                } catch (IOException error) { last = error; }
                finally { connection.disconnect(); }
            }
        }
        throw new IOException("猫源下载失败：" + uri.getHost(), last);
    }

    private static URI sibling(String url, boolean config, boolean checksum) {
        URI uri = URI.create(url);
        String path = uri.getRawPath();
        path = path.substring(0, path.length() - 4);
        if (config) path = path.substring(0, path.length() - 3) + ".config.js";
        if (checksum) path += ".md5";
        return URI.create(uri.getScheme() + "://" + uri.getRawAuthority() + path
                + (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery()));
    }

    private static String digest(String value) throws IOException {
        String normalized = value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
        if (!normalized.matches("[a-f0-9]{32}")) throw new IOException("猫源 MD5 校验文件无效");
        return normalized;
    }
    static boolean validRoute(String route) {
        if (route == null || !route.startsWith("/spider/")) return false;
        try {
            URI uri = URI.create(route);
            return uri.getRawQuery() == null && uri.getRawFragment() == null
                    && uri.getPath().matches("/spider/[\\p{L}\\p{N}_-]+(?:/[0-9]+)?");
        } catch (IllegalArgumentException error) { return false; }
    }
    static String text(Object value) { return value == null ? "" : String.valueOf(value); }
    private static int port(Object value) throws IOException {
        int port = value instanceof Number ? ((Number)value).intValue() : 0;
        if (port < 1 || port > 65535) throw new IOException("Invalid cat port");
        return port;
    }
    static String hash(String algorithm, byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance(algorithm).digest(bytes)); }
        catch (Exception error) { throw new IllegalStateException(error); }
    }
}
