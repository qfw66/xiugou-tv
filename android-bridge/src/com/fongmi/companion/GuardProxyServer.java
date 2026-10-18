package com.fongmi.companion;

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.BindException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * 加固载荷（ftyguard/wexguard）本地代理宿主。
 *
 * 手机端由 TVBox 宿主在固定端口起 NanoHTTPD，并把 /proxy?do=... 交给
 * 载荷的 com.github.catvod.spider.ProxyOrigin#proxy(Map) 处理；载荷里的静态字段
 * ProxyOrigin.yq 就是该端口。桌面端没有这层宿主，yq 保持 -1，于是所有加固站点
 * 的播放地址都是 http://127.0.0.1:-1/proxy?...（糯米/T4 等实测）。
 *
 * 这里补上宿主行为：
 *   1) 在 6677-6999 里绑定一个空闲端口（与手机端 drivePort() 的探测区间一致）；
 *   2) 反射把该端口写进 ProxyOrigin.yq（drivePort() 见到区间内端口会直接复用）；
 *   3) 起 HttpServer，把 /proxy 的 query 参数交给 ProxyOrigin.proxy(Map)，
 *      按返回的 {code, contentType, InputStream} 原样回写。
 *
 * 每个 jar ClassLoader 各自持有独立的 ProxyOrigin 静态状态，因此按 loader 隔离。
 */
public final class GuardProxyServer {

    private static final int PORT_MIN = 9978;
    private static final int PORT_MAX = 10000; // exclusive
    /**
     * 小响应整体缓冲上限：播放列表通常几十 KB~几百 KB，缓冲后可用 Content-Length 回复，
     * 播放器才会把它当"可定位的普通资源"解析。超过该体量按 chunked 流式转发。
     */
    private static final int MAX_BUFFERED_BYTES = 16 * 1024 * 1024;

    private static final Map<ClassLoader, HttpServer> SERVERS = new ConcurrentHashMap<>();
    private static final Map<ClassLoader, Integer> PORTS = new ConcurrentHashMap<>();
    private static final Map<ClassLoader, Method> PROXY_METHODS = new ConcurrentHashMap<>();
    /** 结构性失败（没有 ProxyOrigin.proxy(Map)）：不再重复 bind，避免端口泄漏。 */
    private static final Map<ClassLoader, String> BLOCKED = new ConcurrentHashMap<>();
    /** 端口注入失败原因：已知不可注入时不再反复尝试。 */
    private static final Map<ClassLoader, String> INJECT_FAILED = new ConcurrentHashMap<>();
    /** 成员清单只打印一次（按 ProxyOrigin 类身份）。 */
    private static final Set<Class<?>> MEMBERS_LOGGED =
            Collections.newSetFromMap(new WeakHashMap<Class<?>, Boolean>());

    private static final Pattern PORT_NAME =
            Pattern.compile("(?i)^(yq|port|proxyport|serverport|localport|proxy_port|port_yq)$");
    private static final Pattern METHOD_HINT = Pattern.compile("(?i).*(port|init).*");

    private GuardProxyServer() {
    }

    /**
     * 若该 ClassLoader 里存在载荷 ProxyOrigin，则确保本地 /proxy 服务已就绪。
     * 非加固 jar 会静默跳过（ClassNotFoundException）。
     */
    public static void ensureStarted(ClassLoader loader) {
        if (loader == null) return;
        if (SERVERS.containsKey(loader)) {
            // 幂等：init 之后再次调用只做「端口是否被载荷改写」的复核。
            reassertPort(loader);
            return;
        }
        if (BLOCKED.containsKey(loader)) return;
        synchronized (GuardProxyServer.class) {
            if (SERVERS.containsKey(loader)) {
                reassertPort(loader);
                return;
            }
            if (BLOCKED.containsKey(loader)) return;
            Class<?> proxyClass;
            try {
                proxyClass = Class.forName("com.github.catvod.spider.ProxyOrigin", false, loader);
            } catch (Throwable notGuardPayload) {
                return;   // 非加固 jar：静默跳过
            }
            Method proxy;
            try {
                proxy = proxyClass.getDeclaredMethod("proxy", Map.class);
                proxy.setAccessible(true);
            } catch (Throwable noProxy) {
                // 没有 proxy(Map) 说明不是载荷：**不绑定端口**，避免白占一个 99xx
                String why = "ProxyOrigin.proxy(Map) 不存在: " + noProxy;
                BLOCKED.put(loader, why);
                ParseStage.fail(ParseStage.PROXY, why);
                System.err.println("[GuardProxy] skip（不绑定端口）: " + why);
                return;
            }
            HttpServer server = null;
            try {
                server = bindFreePort();
                int port = server.getAddress().getPort();
                // ProxyOrigin.Gc() 的判据：yq >= 9978 直接复用，否则从 9978 逐个探测到 10000。
                // 因此这里必须落在 [9978,10000)，否则载荷会反复探测并把 yq 留在无效值。
                ExecutorService pool = Executors.newCachedThreadPool(r -> {
                    Thread t = new Thread(r, "guard-proxy-" + port);
                    t.setDaemon(true);
                    return t;
                });
                server.setExecutor(pool);
                server.createContext("/", exchange -> handle(exchange, proxyClass, proxy));
                // ① 先把服务起起来：代理可用性**不依赖**端口注入是否成功。
                //    历史实现先 setPort 再 start，一旦载荷的端口字段不叫 yq（wexguard 变体），
                //    注入异常会把整个服务一起掐死，而端口已经 bind 占住且不释放。
                server.start();
                SERVERS.put(loader, server);
                PORTS.put(loader, port);
                PROXY_METHODS.put(loader, proxy);
                System.out.println("[GuardProxy] started on 127.0.0.1:" + port
                        + " for payload ProxyOrigin in " + loader);

                // ② 再尽力注入端口：让载荷的 getOwnProxyUrl()/内部自请求指向本服务。
                if (Boolean.getBoolean("tvm.companion.proxyDebug")) {
                    dumpMembersOnce(proxyClass);
                }
                Injection injection = injectPort(proxyClass, port);
                if (injection.ok) {
                    System.out.println("[GuardProxy] inject port ok via " + injection.via
                            + (injection.changed ? " (was " + injection.previous + ")" : " (unchanged)"));
                } else {
                    INJECT_FAILED.put(loader, injection.detail);
                    dumpMembersOnce(proxyClass);
                    ParseStage.fail(ParseStage.PROXY, "inject port failed: " + injection.detail);
                    System.err.println("[GuardProxy] inject port failed（服务仍在运行，靠载荷端口探测命中）: "
                            + injection.detail);
                }
            } catch (Throwable t) {
                // 起服务本身失败：释放已绑定的端口，避免每次调用泄漏一个；并缓存失败，避免反复 bind
                if (server != null) {
                    try {
                        server.stop(0);
                    } catch (Throwable ignored) {
                    }
                }
                BLOCKED.put(loader, String.valueOf(t));
                ParseStage.fail(ParseStage.PROXY, t.toString());
                System.err.println("[GuardProxy] start failed: " + t);
            }
        }
    }

    /**
     * init 之后复核端口：载荷可能在自己的初始化里把端口字段改回 -1 或另一个值。
     * 只有「之前注入成功」才复核；已知不可注入的不再反复尝试（避免刷屏）。
     */
    private static void reassertPort(ClassLoader loader) {
        Integer port = PORTS.get(loader);
        if (port == null || INJECT_FAILED.containsKey(loader)) return;
        try {
            Class<?> proxyClass = Class.forName("com.github.catvod.spider.ProxyOrigin", false, loader);
            Injection injection = injectPort(proxyClass, port);
            if (!injection.ok) {
                INJECT_FAILED.put(loader, injection.detail);
                System.err.println("[GuardProxy] port re-inject failed: " + injection.detail);
            } else if (injection.changed) {
                System.out.println("[GuardProxy] port re-injected after init: " + port
                        + " (was " + injection.previous + ")");
            }
        } catch (Throwable ignored) {
        }
    }

    public static int portOf(ClassLoader loader) {
        Integer p = PORTS.get(loader);
        return p != null ? p : -1;
    }

    private static HttpServer bindFreePort() throws Exception {
        Throwable last = null;
        for (int port = PORT_MIN; port < PORT_MAX; port++) {
            try {
                return HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), port), 64);
            } catch (BindException busy) {
                last = busy;
            }
        }
        throw new IllegalStateException("no free port in " + PORT_MIN + "-" + (PORT_MAX - 1), last);
    }

    /** 端口注入结果。 */
    private static final class Injection {
        final boolean ok;
        final boolean changed;
        final int previous;
        final String via;
        final String detail;

        private Injection(boolean ok, boolean changed, int previous, String via, String detail) {
            this.ok = ok;
            this.changed = changed;
            this.previous = previous;
            this.via = via;
            this.detail = detail;
        }

        static Injection ok(boolean changed, int previous, String via) {
            return new Injection(true, changed, previous, via, "");
        }

        static Injection fail(String detail) {
            return new Injection(false, false, 0, "", detail);
        }
    }

    /**
     * 端口注入：不再假设字段名是 {@code yq}。
     *
     * <p>ftyguard 载荷是 {@code static int yq}，但 wexguard 变体的字段名不同
     * （实测 {@code NoSuchFieldException: yq}）。这里按「名字匹配 → 值为 -1 的占位
     * int → 静态 setter」三级降级，每一步都**写入后读回校验**。
     * {@code static final} 在 JDK 21 反射不可写，候选里直接排除。
     */
    private static Injection injectPort(Class<?> proxyClass, int port) {
        List<Field> candidates = portCandidates(proxyClass);
        StringBuilder seen = new StringBuilder();
        for (Field f : candidates) {
            if (seen.length() > 0) seen.append(", ");
            seen.append(describe(f));
            int previous;
            try {
                Object now = f.get(null);
                previous = now instanceof Number ? ((Number) now).intValue() : Integer.MIN_VALUE;
            } catch (Throwable t) {
                continue;
            }
            if (previous == port) {
                Integer exposed = readPort(proxyClass);
                if (exposed == null || exposed == port) {
                    return Injection.ok(false, previous, "field " + f.getName());
                }
                // 字段值是我们写的，但载荷暴露的端口不同：继续往下写（可能被 init 重置过）
            }
            try {
                f.setAccessible(true);
                if (f.getType() == int.class) {
                    f.setInt(null, port);
                } else {
                    f.set(null, Integer.valueOf(port));
                }
                Object now = f.get(null);
                if (now instanceof Number && ((Number) now).intValue() == port) {
                    Integer exposed = readPort(proxyClass);
                    if (exposed == null || exposed == port) {
                        return Injection.ok(true, previous, "field " + f.getName()
                                + (exposed != null ? "（getPort 复核通过）" : ""));
                    }
                }
            } catch (Throwable writeFailed) {
                // 例如 static final / 类初始化失败：记下原因并继续下一个候选
            }
        }
        for (String name : new String[]{"setPort", "setProxyPort", "port", "initPort"}) {
            try {
                Method m = proxyClass.getDeclaredMethod(name, int.class);
                m.setAccessible(true);
                m.invoke(null, port);
                return Injection.ok(true, 0, "method " + name + "(int)");
            } catch (Throwable ignored) {
            }
        }
        return Injection.fail("没有可写的静态 int 字段或 setter; candidates=[" + seen + "]");
    }

    /** 端口候选：名字匹配的优先，其次是「值为 -1（未设置）」的静态 int。 */
    private static List<Field> portCandidates(Class<?> proxyClass) {
        List<Field> all = new ArrayList<>();
        List<Field> named = new ArrayList<>();
        List<Field> unset = new ArrayList<>();
        for (Class<?> c = proxyClass; c != null && c != Object.class; c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                int mod = f.getModifiers();
                if (!Modifier.isStatic(mod) || Modifier.isFinal(mod)) continue;
                if (f.getType() != int.class && f.getType() != Integer.class) continue;
                all.add(f);
                if (PORT_NAME.matcher(f.getName()).matches()) {
                    named.add(f);
                    continue;
                }
                // 只接受「-1」这种明确的未设置哨兵；0 更可能是计数器，写进去会污染载荷状态
                try {
                    f.setAccessible(true);
                    Object v = f.get(null);
                    if (v instanceof Number && ((Number) v).intValue() == -1) unset.add(f);
                } catch (Throwable ignored) {
                }
            }
        }
        List<Field> result = new ArrayList<>(named);
        result.addAll(unset);
        // 唯一静态 int 字段：没有别的候选时它就是端口的事实候选。
        // 实测 wexguard 载荷：{fields=[b:int=0] methods=[init(0), getPort(0)]}，
        // 且写入后可用 getPort() 复核，因此「值不是 -1」不再是硬性排除条件。
        if (result.isEmpty() && all.size() == 1) {
            result.add(all.get(0));
        }
        return result;
    }

    /**
     * 载荷若用 {@code getPort()} 暴露端口，写字段后必须由它复核 ——
     * 否则可能写进了同名的无关字段（如计数器），把载荷状态改坏。
     */
    private static Integer readPort(Class<?> proxyClass) {
        try {
            Method m = proxyClass.getDeclaredMethod("getPort");
            m.setAccessible(true);
            Object v = m.invoke(null);
            if (v instanceof Number) return ((Number) v).intValue();
        } catch (Throwable ignored) {
        }
        return null;
    }

    private static String describe(Field f) {
        String value;
        try {
            f.setAccessible(true);
            value = String.valueOf(f.get(null));
        } catch (Throwable t) {
            value = "?";
        }
        String type = f.getType() == int.class ? "int" : f.getType().getSimpleName();
        return f.getName() + ":" + type + (Modifier.isFinal(f.getModifiers()) ? ":final" : "") + "=" + value;
    }

    /** 一次性打印 ProxyOrigin 的静态 int/String 字段与 port/init 方法，供排查用。 */
    private static void dumpMembersOnce(Class<?> proxyClass) {
        if (!MEMBERS_LOGGED.add(proxyClass)) return;
        StringBuilder fields = new StringBuilder();
        for (Class<?> c = proxyClass; c != null && c != Object.class; c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                if (!Modifier.isStatic(f.getModifiers())) continue;
                if (f.getType() != int.class && f.getType() != Integer.class && f.getType() != String.class) continue;
                if (fields.length() > 0) fields.append(", ");
                fields.append(describe(f));
            }
        }
        StringBuilder methods = new StringBuilder();
        for (Method m : proxyClass.getDeclaredMethods()) {
            if (!Modifier.isStatic(m.getModifiers())) continue;
            if (!METHOD_HINT.matcher(m.getName()).matches()) continue;
            if (methods.length() > 0) methods.append(", ");
            methods.append(m.getName()).append('(').append(m.getParameterCount()).append(')');
        }
        System.out.println("[GuardProxy] ProxyOrigin members: fields=[" + fields + "] methods=[" + methods + "]"
                + (readPort(proxyClass) != null ? " getPort=" + readPort(proxyClass) : ""));
    }

    /** 配置切换 / 加载器清理时释放所有本地代理，避免端口与线程泄漏。 */
    public static void releaseAll() {
        synchronized (GuardProxyServer.class) {
            for (HttpServer server : SERVERS.values()) {
                try {
                    server.stop(0);
                } catch (Throwable ignored) {
                }
            }
            SERVERS.clear();
            PORTS.clear();
            PROXY_METHODS.clear();
            BLOCKED.clear();
            INJECT_FAILED.clear();
            MEMBERS_LOGGED.clear();
        }
    }

    /** 路径式代理入口前缀：`/proxy/<base64url(query)>`。 */
    public static final String TOKEN_PREFIX = "/proxy/";

    private static final java.util.regex.Pattern LOCAL_PROXY_URL = java.util.regex.Pattern.compile(
            "http://127\\.0\\.0\\.1:(\\d+)/proxy\\?([^\"'\\s\\\\]+)");

    /**
     * 把载荷生成的 `http://127.0.0.1:<port>/proxy?do=..&url=..` 改写为
     * `http://127.0.0.1:<port>/proxy/<base64url(query)>`。
     *
     * 原因：mpv（media_kit 走 loadfile）会把 URL 里第一个 `&` 之后的内容丢掉，
     * 实测请求行只剩 `GET /proxy?do=m3u8`，载荷因此拿不到 url 参数，返回空流，
     * 播放器报 "Failed to recognize file format."。路径里没有 `&`，可以完整保留。
     */
    public static String rewriteLocalProxyUrls(String text) {
        if (text == null || text.indexOf("/proxy?") < 0) return text;
        java.util.regex.Matcher matcher = LOCAL_PROXY_URL.matcher(text);
        StringBuilder out = new StringBuilder(text.length() + 128);
        while (matcher.find()) {
            String query = matcher.group(2);
            String token = java.util.Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(query.getBytes(StandardCharsets.UTF_8));
            matcher.appendReplacement(out, java.util.regex.Matcher.quoteReplacement(
                    "http://127.0.0.1:" + matcher.group(1) + TOKEN_PREFIX + token));
        }
        matcher.appendTail(out);
        return out.toString();
    }

    private static String decodeToken(String token) {
        try {
            byte[] raw = java.util.Base64.getUrlDecoder().decode(token);
            return new String(raw, StandardCharsets.UTF_8);
        } catch (Throwable t) {
            return null;
        }
    }

    /** 调用载荷的 ProxyOrigin.proxy(Map)，并把反射异常还原成真实原因。 */
    private static Object[] invokeProxy(Method proxy, Map<String, String> params) throws Exception {
        try {
            return (Object[]) proxy.invoke(null, params);
        } catch (InvocationTargetException ite) {
            Throwable cause = ite.getCause() != null ? ite.getCause() : ite;
            if (cause instanceof Exception) throw (Exception) cause;
            throw new RuntimeException(cause);
        }
    }

    private static void handle(HttpExchange exchange, Class<?> proxyClass, Method proxy) {
        String path = exchange.getRequestURI().getPath();
        String rawQuery = exchange.getRequestURI().getRawQuery();
        // 两种入口形态：
        //   /proxy?do=...&url=...      —— 载荷原生形态（curl/其它宿主）
        //   /proxy/<base64url(query)>  —— 给播放器用：mpv/media_kit 会在第一个 '&' 处截断 URL，
        //                                 实测请求行只到 "GET /proxy?do=m3u8"，后续参数全丢，
        //                                 于是载荷拿不到 url → 空流 → "Failed to recognize file format."
        if (path.startsWith(TOKEN_PREFIX)) {
            String token = path.substring(TOKEN_PREFIX.length());
            String decoded = decodeToken(token);
            if (decoded == null) {
                sendText(exchange, 404, "bad proxy token");
                return;
            }
            rawQuery = decoded;
        }
        Map<String, String> params = parseQuery(rawQuery);
        long t0 = System.currentTimeMillis();
        // 载荷的端口探测握手（见 CatVod 参考实现 Proxy.a()）：
        //   GET /proxy?do=ck 期望正文恰好是 "ok"，否则它会继续探测下一个端口。
        // 这里直接短路应答，不依赖载荷自己的 proxy() 是否实现了 ck 分支 ——
        // 这样即便端口注入失败，载荷也能发现本服务（注入退化为可选优化）。
        if ("ck".equals(params.get("do"))) {
            sendText(exchange, 200, "ok");
            return;
        }
        try {
            Object[] arr = invokeProxy(proxy, params);
            if (arr == null || arr.length < 3 || arr[2] == null) {
                sendText(exchange, 404, "not found: " + path);
                return;
            }
            int code = ((Number) arr[0]).intValue();
            String contentType = arr[1] == null ? "" : String.valueOf(arr[1]);
            InputStream in = (InputStream) arr[2];

            Headers headers = exchange.getResponseHeaders();
            headers.set("Access-Control-Allow-Origin", "*");
            headers.set("Access-Control-Allow-Headers", "*");
            headers.set("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
            if (!contentType.isEmpty()) headers.set("Content-Type", contentType);

            // 关键：不要用 chunked 回复播放器。
            // 实测（mpv 0.36 / ffmpeg 6.0）：同一份 m3u8 由普通静态服务（带 Content-Length）
            // 托管时能正常解析出时长，走本代理的 chunked 无长度响应则报
            // "Failed to recognize file format."。播放器会把不可定位的流当成可流式容器去嗅探。
            // 因此：小响应（播放列表）整体缓冲后带 Content-Length + Accept-Ranges 返回，
            // 并支持 Range(206)；超大响应才退回 chunked 边读边写。
            byte[] pending;
            boolean complete;
            {
                Prefetch prefetched = prefetch(in, MAX_BUFFERED_BYTES);
                pending = prefetched.bytes;
                complete = prefetched.complete;
            }
            // 载荷偶发返回空流（实测：刚启动后的第一次 proxy 调用，返回 0 字节）。
            // 播放器只发一次请求，拿到空体就报 "Failed to recognize file format."，
            // 所以这里对"完整但为空"的响应重试一次。
            if (complete && pending.length == 0) {
                Thread.sleep(300);
                Object[] retry = invokeProxy(proxy, params);
                if (retry != null && retry.length >= 3 && retry[2] != null) {
                    try (InputStream second = (InputStream) retry[2]) {
                        Prefetch again = prefetch(second, MAX_BUFFERED_BYTES);
                        if (again.bytes.length > 0) {
                            pending = again.bytes;
                            complete = again.complete;
                            System.out.println("[GuardProxy] empty response retried ok: " + again.bytes.length + " bytes");
                        }
                    }
                }
            }

            if (complete) {
                byte[] body = pending;
                long total = body.length;
                headers.set("Accept-Ranges", "bytes");
                String range = exchange.getRequestHeaders().getFirst("Range");
                long[] span = parseRange(range, total);
                boolean head = "HEAD".equalsIgnoreCase(exchange.getRequestMethod());
                if (span != null) {
                    int start = (int) span[0];
                    int length = (int) (span[1] - span[0] + 1);
                    headers.set("Content-Range", "bytes " + span[0] + "-" + span[1] + "/" + total);
                    exchange.sendResponseHeaders(206, head ? -1 : length);
                    if (!head) {
                        try (OutputStream out = exchange.getResponseBody()) {
                            out.write(body, start, length);
                        }
                    }
                } else {
                    exchange.sendResponseHeaders(code, head ? -1 : total);
                    if (!head) {
                        try (OutputStream out = exchange.getResponseBody()) {
                            out.write(body);
                        }
                    }
                }
                log(path, params, code, contentType, total, range, t0, "buffered");
                exchange.close();
                return;
            }

            // 超大响应：先发头，再把已读部分与剩余部分顺序写出（chunked）
            headers.set("Accept-Ranges", "none");
            exchange.sendResponseHeaders(code, 0);
            long written = 0;
            try (InputStream src = in; OutputStream out = exchange.getResponseBody()) {
                out.write(pending);
                written += pending.length;
                byte[] buf = new byte[32 * 1024];
                int n;
                while ((n = src.read(buf)) != -1) {
                    out.write(buf, 0, n);
                    written += n;
                }
                out.flush();
            }
            log(path, params, code, contentType, written,
                    exchange.getRequestHeaders().getFirst("Range"), t0, "streamed");
        } catch (InvocationTargetException ite) {
            Throwable cause = ite.getCause() != null ? ite.getCause() : ite;
            System.err.println("[GuardProxy] proxy error: " + cause);
            cause.printStackTrace();
            sendText(exchange, 500, "proxy error: " + cause);
        } catch (Throwable t) {
            System.err.println("[GuardProxy] handle error: " + t);
            sendText(exchange, 500, "error: " + t);
        }
    }

    private static void sendText(HttpExchange exchange, int code, String body) {
        try {
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
            exchange.sendResponseHeaders(code, bytes.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(bytes);
            }
        } catch (Throwable ignored) {
        } finally {
            exchange.close();
        }
    }

    private static void copy(InputStream in, OutputStream out) throws java.io.IOException {
        byte[] buf = new byte[16 * 1024];
        int n;
        while ((n = in.read(buf)) != -1) {
            out.write(buf, 0, n);
        }
        out.flush();
    }

    /** 最多预读 [limit] 字节；读满窗口但未见 EOF 时 complete=false（转流式输出）。 */
    private static Prefetch prefetch(InputStream in, int limit) throws java.io.IOException {
        java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream(Math.min(limit, 64 * 1024));
        byte[] buf = new byte[16 * 1024];
        while (buffer.size() < limit) {
            int room = Math.min(buf.length, limit - buffer.size());
            int n = in.read(buf, 0, room);
            if (n < 0) return new Prefetch(buffer.toByteArray(), true);
            buffer.write(buf, 0, n);
        }
        return new Prefetch(buffer.toByteArray(), false);
    }

    private static final class Prefetch {
        final byte[] bytes;
        final boolean complete;

        Prefetch(byte[] bytes, boolean complete) {
            this.bytes = bytes;
            this.complete = complete;
        }
    }

    /**
     * 解析 `Range: bytes=a-b` / `bytes=a-` / `bytes=-n`。
     * 返回 [start, endInclusive]，无法解析或不必要时返回 null（按整份返回）。
     */
    private static long[] parseRange(String header, long total) {
        if (header == null || total <= 0) return null;
        String value = header.trim();
        if (!value.toLowerCase(java.util.Locale.ROOT).startsWith("bytes=")) return null;
        value = value.substring(6).trim();
        int comma = value.indexOf(',');
        if (comma > 0) value = value.substring(0, comma).trim();
        int dash = value.indexOf('-');
        if (dash < 0) return null;
        String startText = value.substring(0, dash).trim();
        String endText = value.substring(dash + 1).trim();
        try {
            long start;
            long end;
            if (startText.isEmpty()) {
                // 后缀区间：最后 n 字节
                long suffix = Long.parseLong(endText);
                if (suffix <= 0) return null;
                start = Math.max(0, total - suffix);
                end = total - 1;
            } else {
                start = Long.parseLong(startText);
                end = endText.isEmpty() ? total - 1 : Long.parseLong(endText);
            }
            if (start < 0 || start >= total) return null;
            if (end >= total) end = total - 1;
            if (end < start) return null;
            return new long[]{start, end};
        } catch (Throwable t) {
            return null;
        }
    }

    private static void log(String path, Map<String, String> params, int code, String contentType,
                            long bytes, String range, long startedAt, String mode) {
        System.out.println("[GuardProxy] " + path + " do=" + params.get("do")
                + " code=" + code + " ct=" + contentType
                + " bytes=" + bytes + (range != null ? " range=" + range : "")
                + " (" + mode + ") " + (System.currentTimeMillis() - startedAt) + "ms");
    }

    private static Map<String, String> parseQuery(String rawQuery) {
        Map<String, String> map = new LinkedHashMap<>();
        if (rawQuery == null || rawQuery.isEmpty()) return map;
        for (String pair : rawQuery.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String key = eq < 0 ? pair : pair.substring(0, eq);
            String value = eq < 0 ? "" : pair.substring(eq + 1);
            map.put(decode(key), decode(value));
        }
        return map;
    }

    private static String decode(String s) {
        try {
            return URLDecoder.decode(s, "UTF-8");
        } catch (Throwable t) {
            return s;
        }
    }
}
