package com.fongmi.companion;

import com.github.catvod.utils.DebugLog;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/**
 * 网盘直链的分块并发代理：替代载荷 8096 多线程加速代理（ARM {@code libwexproxy.so}，Windows 起不来）。
 *
 * 网盘 CDN 对单连接限速（夸克实测单连接 1.48 MB/s，8 并发 × 1 MB 达 4.0 MB/s），
 * 所以把播放器的一个 Range 请求拆成多个 1 MB 的上游 Range 请求并发拉取、按序写回。
 * 方案与实测见 docs/NETDISK_PLAYBACK_PLAN.md。
 *
 * 入口 {@code /netdisk/<id>}；id 由 {@link #register} 登记（直链 + 载荷给的请求头）。
 * 并发窗口慢启动（2 起、每交付一块 +1、封顶 8）：mpv 探测容器尾部索引时只读一小段就断开，
 * 不能每次都白拉 8 MB。播放器断开即断开所有在途上游连接。
 */
public final class NetdiskChunkProxy implements HttpHandler {

    public static final String PREFIX = "/netdisk/";

    static final int FIRST_CHUNK = 256 * 1024;
    static final int CHUNK = 1024 * 1024;
    static final int START_WINDOW = 2;
    static final int MAX_WINDOW = 8;
    static final int ATTEMPTS = 3;
    private static final int MAX_ENTRIES = 64;
    private static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final int READ_TIMEOUT_MS = 20_000;

    private static volatile int localPort;
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final Map<String, Entry> ENTRIES = Collections.synchronizedMap(
            new LinkedHashMap<String, Entry>(16, 0.75f, true) {
                @Override
                protected boolean removeEldestEntry(Map.Entry<String, Entry> eldest) {
                    return size() > MAX_ENTRIES;
                }
            });
    private static final ExecutorService POOL = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r, "netdisk-chunk");
        t.setDaemon(true);
        return t;
    });

    /** 一条登记的直链。total / rangeOk 由首次探测填充。 */
    static final class Entry {
        final String url;
        final Map<String, String> headers;
        long total = -1;
        String contentType;
        Boolean rangeOk;

        Entry(String url, Map<String, String> headers) {
            this.url = url;
            this.headers = headers;
        }
    }

    /** 上游返回了非预期状态码。4xx（链接过期 / 未登录 / 无权限）不重试。 */
    static final class UpstreamStatus extends IOException {
        final int code;

        UpstreamStatus(int code) {
            super("upstream HTTP " + code);
            this.code = code;
        }

        boolean fatal() {
            return code >= 400 && code < 500;
        }
    }

    /** SpiderServer 绑定端口后调用；为 0 时 {@link #register} 不启用代理。 */
    public static void setLocalPort(int port) {
        localPort = port;
    }

    /** 登记直链，返回本机代理地址；代理未就绪时返回 null（调用方退回直链）。 */
    public static String register(String url, Map<String, String> headers) {
        int port = localPort;
        if (port <= 0) return null;
        byte[] raw = new byte[12];
        RANDOM.nextBytes(raw);
        StringBuilder id = new StringBuilder();
        for (byte b : raw) id.append(String.format("%02x", b));
        ENTRIES.put(id.toString(), new Entry(url, headers == null ? Collections.emptyMap() : headers));
        return "http://127.0.0.1:" + port + PREFIX + id;
    }

    @Override
    public void handle(HttpExchange exchange) {
        try {
            serve(exchange);
        } catch (IOException e) {
            // 播放器拖动 / 换集 / 关闭时主动断开，属正常路径
        } catch (Throwable t) {
            DebugLog.line("Netdisk", "代理异常: " + t);
        } finally {
            exchange.close();
        }
    }

    private void serve(HttpExchange exchange) throws IOException {
        String path = exchange.getRequestURI().getPath();
        Entry entry = ENTRIES.get(path.substring(Math.min(path.length(), PREFIX.length())));
        if (entry == null) {
            sendText(exchange, 404, "unknown netdisk stream");
            return;
        }
        boolean head = "HEAD".equalsIgnoreCase(exchange.getRequestMethod());
        try {
            probe(entry);
        } catch (UpstreamStatus e) {
            sendText(exchange, e.code, "upstream " + e.code);
            return;
        }
        if (!entry.rangeOk) {
            passthrough(exchange, entry, head);
            return;
        }
        String rangeHeader = exchange.getRequestHeaders().getFirst("Range");
        long[] range = parseRange(rangeHeader, entry.total);
        var out = exchange.getResponseHeaders();
        out.set("Accept-Ranges", "bytes");
        if (entry.contentType != null) out.set("Content-Type", entry.contentType);
        if (range != null && range[0] < 0) {
            out.set("Content-Range", "bytes */" + entry.total);
            exchange.sendResponseHeaders(416, -1);
            return;
        }
        long start = range == null ? 0 : range[0];
        long end = range == null ? entry.total - 1 : range[1];
        long length = end - start + 1;
        if (range != null) out.set("Content-Range", "bytes " + start + "-" + end + "/" + entry.total);
        if (head) {
            out.set("Content-Length", Long.toString(length));
            exchange.sendResponseHeaders(range == null ? 200 : 206, -1);
            return;
        }
        exchange.sendResponseHeaders(range == null ? 200 : 206, length);
        long t0 = System.currentTimeMillis();
        long[] sent = {0};
        try (OutputStream body = exchange.getResponseBody()) {
            stream(entry, start, end, body, sent);
        } finally {
            long ms = Math.max(1, System.currentTimeMillis() - t0);
            DebugLog.line("Netdisk", String.format("bytes=%d-%d 交付 %.1f MB / %d ms（%.2f MB/s）",
                    start, end, sent[0] / 1048576.0, ms, sent[0] / 1048576.0 / (ms / 1000.0)));
        }
    }

    /**
     * 解析单段 Range。返回 null：无 Range / 多段 / 不认识（按整段 200 处理，RFC 9110 允许忽略）；
     * 返回 {-1,-1}：不可满足（416）；否则 {start,end}，end 已截到 total-1。
     */
    static long[] parseRange(String header, long total) {
        if (header == null) return null;
        String h = header.trim();
        if (!h.startsWith("bytes=") || h.indexOf(',') >= 0) return null;
        String spec = h.substring(6).trim();
        int dash = spec.indexOf('-');
        if (dash < 0) return null;
        try {
            String a = spec.substring(0, dash).trim();
            String b = spec.substring(dash + 1).trim();
            if (a.isEmpty()) {
                if (b.isEmpty()) return null;
                long suffix = Long.parseLong(b);
                if (suffix <= 0) return new long[]{-1, -1};
                return new long[]{Math.max(0, total - suffix), total - 1};
            }
            long start = Long.parseLong(a);
            long end = b.isEmpty() ? total - 1 : Math.min(Long.parseLong(b), total - 1);
            if (start >= total || start > end) return new long[]{-1, -1};
            return new long[]{start, end};
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** 并发窗口拉取 [start,end]，按序写给播放器；sent[0] 实时累计已写出字节（播放器中途断开时也准确）。 */
    static void stream(Entry entry, long start, long end, OutputStream body, long[] sent) throws IOException {
        ArrayDeque<Chunk> inflight = new ArrayDeque<>();
        int window = START_WINDOW;
        long next = start;
        try {
            while (true) {
                while (inflight.size() < window && next <= end) {
                    long size = next == start ? FIRST_CHUNK : CHUNK;
                    long to = Math.min(end, next + size - 1);
                    Chunk chunk = new Chunk(entry, next, to);
                    chunk.future = POOL.submit(chunk);
                    inflight.add(chunk);
                    next = to + 1;
                }
                Chunk head = inflight.poll();
                if (head == null) break;
                byte[] data = head.await();
                body.write(data);
                sent[0] += data.length;
                if (window < MAX_WINDOW) window++;
            }
            body.flush();
        } finally {
            for (Chunk chunk : inflight) chunk.cancel();
        }
    }

    /** 一个上游 Range 块；cancel 会断开在途连接，让阻塞的读立即失败。 */
    static final class Chunk implements java.util.concurrent.Callable<byte[]> {
        final Entry entry;
        final long from;
        final long to;
        Future<byte[]> future;
        private volatile HttpURLConnection connection;
        private volatile boolean cancelled;

        Chunk(Entry entry, long from, long to) {
            this.entry = entry;
            this.from = from;
            this.to = to;
        }

        @Override
        public byte[] call() throws IOException {
            IOException last = null;
            for (int attempt = 1; attempt <= ATTEMPTS && !cancelled; attempt++) {
                try {
                    return fetch();
                } catch (UpstreamStatus e) {
                    if (e.fatal()) throw e;
                    last = e;
                } catch (IOException e) {
                    last = e;
                }
            }
            throw last != null ? last : new IOException("cancelled");
        }

        private byte[] fetch() throws IOException {
            HttpURLConnection conn = open(entry, "bytes=" + from + "-" + to);
            connection = conn;
            if (cancelled) conn.disconnect();
            int code = conn.getResponseCode();
            if (code != 206) {
                drain(conn);
                throw new UpstreamStatus(code);
            }
            int expected = (int) (to - from + 1);
            try (InputStream in = conn.getInputStream()) {
                byte[] data = in.readNBytes(expected);
                if (data.length != expected) {
                    throw new IOException("short chunk " + data.length + "/" + expected + " @" + from);
                }
                return data;
            }
        }

        byte[] await() throws IOException {
            try {
                return future.get();
            } catch (ExecutionException e) {
                Throwable cause = e.getCause();
                if (cause instanceof IOException) throw (IOException) cause;
                throw new IOException(cause);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted", e);
            } catch (CancellationException e) {
                throw new IOException("cancelled", e);
            }
        }

        void cancel() {
            cancelled = true;
            if (future != null) future.cancel(true);
            HttpURLConnection conn = connection;
            if (conn != null) conn.disconnect();
        }
    }

    /** 首次访问时用 bytes=0-0 探测：拿总长、类型，确认上游支持 Range。 */
    private static void probe(Entry entry) throws IOException {
        synchronized (entry) {
            if (entry.rangeOk != null) return;
            HttpURLConnection conn = open(entry, "bytes=0-0");
            try {
                int code = conn.getResponseCode();
                String contentRange = conn.getHeaderField("Content-Range");
                long total = parseTotal(contentRange);
                if (code == 206 && total > 0) {
                    entry.total = total;
                    entry.rangeOk = true;
                } else if (code == 200) {
                    entry.total = conn.getContentLengthLong();
                    entry.rangeOk = false;
                } else {
                    throw new UpstreamStatus(code);
                }
                entry.contentType = conn.getContentType();
                drain(conn);
            } catch (IOException e) {
                conn.disconnect();
                throw e;
            }
        }
    }

    static long parseTotal(String contentRange) {
        if (contentRange == null) return -1;
        int slash = contentRange.lastIndexOf('/');
        if (slash < 0) return -1;
        try {
            return Long.parseLong(contentRange.substring(slash + 1).trim());
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** 上游不支持 Range：单连接透传，把播放器的 Range 原样转发。 */
    private static void passthrough(HttpExchange exchange, Entry entry, boolean head) throws IOException {
        HttpURLConnection conn = open(entry, exchange.getRequestHeaders().getFirst("Range"));
        try {
            int code = conn.getResponseCode();
            var out = exchange.getResponseHeaders();
            for (String name : new String[]{"Content-Type", "Content-Range", "Accept-Ranges"}) {
                String value = conn.getHeaderField(name);
                if (value != null) out.set(name, value);
            }
            long length = conn.getContentLengthLong();
            if (head) {
                if (length >= 0) out.set("Content-Length", Long.toString(length));
                exchange.sendResponseHeaders(code, -1);
                return;
            }
            InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            exchange.sendResponseHeaders(code, length >= 0 ? (length == 0 ? -1 : length) : 0);
            if (in == null) return;
            try (InputStream src = in; OutputStream body = exchange.getResponseBody()) {
                src.transferTo(body);
            }
        } finally {
            conn.disconnect();
        }
    }

    private static HttpURLConnection open(Entry entry, String range) throws IOException {
        HttpURLConnection conn = (HttpURLConnection) new URL(entry.url).openConnection();
        conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
        conn.setReadTimeout(READ_TIMEOUT_MS);
        conn.setInstanceFollowRedirects(true);
        for (Map.Entry<String, String> h : entry.headers.entrySet()) {
            String name = h.getKey();
            if (name == null || name.equalsIgnoreCase("Range") || name.equalsIgnoreCase("Host")) continue;
            conn.setRequestProperty(name, h.getValue());
        }
        if (range != null) conn.setRequestProperty("Range", range);
        return conn;
    }

    /** 读完并关闭响应体，让连接回到 keep-alive 池。 */
    private static void drain(HttpURLConnection conn) {
        try {
            InputStream in = conn.getResponseCode() >= 400 ? conn.getErrorStream() : conn.getInputStream();
            if (in != null) {
                try (InputStream s = in) {
                    s.transferTo(OutputStream.nullOutputStream());
                }
            }
        } catch (IOException ignored) {
            conn.disconnect();
        }
    }

    private static void sendText(HttpExchange exchange, int code, String text) throws IOException {
        byte[] body = text.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
        exchange.sendResponseHeaders(code, body.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(body);
        }
    }
}
