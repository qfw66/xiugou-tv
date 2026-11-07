package com.fongmi.companion;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
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
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.stream.Stream;

/**
 * Real HTTP RPC -> Python child -> unmodified author CCTV -> RuntimeNet -> loopback fixtures.
 * Run from the repository root with the desired production classes/jar on the classpath.
 * Override the read-only reference with -Dxiugou.author.cctv=... or XIUGOU_AUTHOR_CCTV;
 * a missing reference prints SKIP before opening any server or creating a test home.
 * PyRuntime accepts -Dxiugou.python=... for the interpreter (including lxml).
 */
public final class AuthorCctvIntegrationTest implements AutoCloseable {
    private static final String DEFAULT_AUTHOR = "E:/code/tvbox_1102/live-python-20261107/live/cctv.py";
    private static final String SITE = "author-cctv + 中文";
    private static final String DATE = "2024-01-02";
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(3)).followRedirects(HttpClient.Redirect.NEVER).build();

    private final Path author;
    private final Path root;
    private final String previousHome = System.getProperty("user.home");
    private final List<UpstreamRequest> requests = new CopyOnWriteArrayList<>();
    private HttpServer upstream;
    private SpiderServer bridge;
    private String upstreamOrigin;
    private String bridgeOrigin;
    private Path wrapper;
    private volatile String manifestField = "manifest";

    private AuthorCctvIntegrationTest(Path author) throws IOException {
        this.author = author;
        root = Files.createTempDirectory("xiugou-author-cctv-").toRealPath();
    }

    public static void main(String[] args) throws Exception {
        String configured = System.getProperty("xiugou.author.cctv");
        if (configured == null || configured.isBlank()) configured = System.getenv("XIUGOU_AUTHOR_CCTV");
        Path source = Path.of(configured == null || configured.isBlank() ? DEFAULT_AUTHOR : configured)
                .toAbsolutePath().normalize();
        if (!Files.isRegularFile(source)) {
            System.out.println("SKIP AuthorCctvIntegrationTest: author source missing; set "
                    + "-Dxiugou.author.cctv or XIUGOU_AUTHOR_CCTV");
            return;
        }
        source = source.toRealPath();
        byte[] originalHash = digest(source);
        try (AuthorCctvIntegrationTest test = new AuthorCctvIntegrationTest(source)) {
            test.start();
            List<Map<?, ?>> channels = test.loadChannels();
            test.catalogAndRouting(channels);
            test.playRedirects(channels.get(0));
            test.epgCache(channels.get(0));
            test.resetAndReload(channels.get(0));
            check(Arrays.equals(originalHash, digest(source)), "author reference must remain byte-for-byte unchanged");
            System.out.println("AuthorCctvIntegrationTest OK (4 real author/HTTP/process boundaries)");
            System.out.println("Author SHA-256: " + HexFormat.of().formatHex(originalHash));
        }
    }

    private void start() throws Exception {
        System.setProperty("user.home", Files.createDirectories(root.resolve("home")).toString());
        upstream = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        upstream.createContext("/", this::serveUpstream);
        upstream.start();
        upstreamOrigin = "http://127.0.0.1:" + upstream.getAddress().getPort();
        wrapper = root.resolve("author_wrapper.py");
        String code = """
                import importlib.util
                import os
                os.environ['NO_PROXY'] = '127.0.0.1,localhost'
                os.environ['no_proxy'] = '127.0.0.1,localhost'
                spec = importlib.util.spec_from_file_location('xiugou_author_cctv', %s)
                author = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(author)
                author.HOST = %s
                author.CATALOG_URL = author.HOST + '/catalog'
                author.EPG_URL = author.HOST + '/epg'
                author.PLAY_URL = author.HOST + '/play'
                Spider = author.Spider
                """.formatted(JsonCodec.stringify(author.toString()), JsonCodec.stringify(upstreamOrigin));
        Files.writeString(wrapper, code, StandardCharsets.UTF_8);
        bridge = new SpiderServer(0);
        bridgeOrigin = "http://127.0.0.1:" + bridge.start();
    }

    private List<Map<?, ?>> loadChannels() throws Exception {
        Map<String, Object> descriptor = new LinkedHashMap<>();
        descriptor.put("key", SITE);
        descriptor.put("siteKey", SITE);
        descriptor.put("api", wrapper.toUri().toString());
        descriptor.put("ext", upstreamOrigin + "/snapshot");
        descriptor.put("jar", "");
        descriptor.put("timeoutMs", 10000);
        rpc("/spider/load", descriptor);
        descriptor.put("method", "liveContent");
        descriptor.put("url", "");
        Object data = rpc("/spider/call", descriptor).get("data");
        List<?> groups = list(data, "liveContent must cross RPC as a JSON group array");
        check(groups.size() == 1, "author must return exactly one group");
        Map<?, ?> group = object(groups.get(0), "group must remain an object");
        check("央視頻道".equals(group.get("name")), "group name must survive UTF-8 transport");
        List<Map<?, ?>> channels = new ArrayList<>();
        for (Object value : list(group.get("channel"), "group.channel must remain an array")) {
            channels.add(object(value, "channel must remain an object"));
        }
        return channels;
    }

    private void catalogAndRouting(List<Map<?, ?>> channels) {
        List<String> ids = channelIds();
        check(channels.size() == 18, "complete original catalog must produce 18 distinct channels");
        String token = query(playUrl(channels.get(0))).get("token");
        check(token != null && !token.isBlank(), "host registration must supply a non-empty token");
        for (int index = 0; index < channels.size(); index++) {
            Map<?, ?> channel = channels.get(index);
            String id = ids.get(index);
            check(id.equals(channel.get("tvgId")), "channel IDs and order must survive RPC");
            check(("频道 " + (index + 1)).equals(channel.get("name")), "channel name must remain UTF-8");
            check(channel.get("name").equals(channel.get("tvgName")), "tvgName must survive RPC");
            check(String.format(Locale.ROOT, "%02d", index + 1).equals(channel.get("number")), "channel numbers must survive RPC");
            check("application/x-mpegURL".equals(channel.get("format")), "author HLS MIME must survive RPC");
            check(string(channel.get("ua"), "channel user agent").startsWith("Mozilla/5.0"), "author user agent must survive RPC");
            check(string(channel.get("logo"), "channel logo").startsWith("https://epg.112114.xyz/logo/"), "logo must survive RPC without being fetched");
            String play = playUrl(channel);
            checkProxyOrigin(play);
            check(query(play).equals(Map.of("token", token, "do", "py", "siteKey", SITE, "id", id)),
                    "play URL must preserve host token/do/siteKey and author channel ID");
            String epgTemplate = string(channel.get("epg"), "EPG template");
            check(epgTemplate.endsWith("&date={date}"), "date placeholder must survive JSON transport");
            String epg = epgTemplate.replace("{date}", DATE);
            checkProxyOrigin(epg);
            check(query(epg).equals(Map.of("token", token, "do", "py", "siteKey", SITE,
                    "id", id, "type", "epg", "date", DATE)), "EPG URL must preserve routing and date");
        }
        check(requests.size() == 1 && requests.get(0).path().equals("/catalog"),
                "catalog must use RuntimeNet once with no snapshot or external media fetch");
        checkHeaders(requests.get(0), channels.get(0));
        System.out.println("PASS 18 channels/group/channel and registered proxy URLs through real RPC");
    }

    private void playRedirects(Map<?, ?> channel) throws Exception {
        for (String field : List.of("manifest", "backup")) {
            manifestField = field;
            long before = count("/play");
            HttpResponse<byte[]> result = request("GET", playUrl(channel), null);
            check(result.statusCode() == 302, "original " + field + " must reach client as HTTP 302");
            check(result.headers().firstValue("Location").orElse("").equals(mediaUrl()),
                    "Location query escaping must survive runner and HTTP without redirects");
            check(result.headers().firstValue("Content-Type").orElse("").equals("text/plain")
                    && result.body().length == 0, "redirect MIME and empty body must survive bridge");
            check(count("/play") == before + 1 && count("/media/live.m3u8") == 0,
                    "each proxy GET must resolve once and leave media fetching to its caller");
            UpstreamRequest observed = last("/play");
            Map<String, String> params = observed.query();
            check("cctv1".equals(params.get("channel")) && "1".equals(params.get("vn"))
                    && "1".equals(params.get("pdrm")) && !params.getOrDefault("uid", "").isEmpty(),
                    "original resolver query must reach the real HTTP adapter");
            String auth = observed.headers().getOrDefault("auth-key", "");
            check(auth.matches("[0-9]+-[0-9]{3}-[0-9a-f]{32}")
                    && auth.split("-")[0].equals(params.get("hbss")), "original auth header and timestamp must reach upstream");
            check(upstreamOrigin.equals(observed.headers().get("origin"))
                    && "XMLHttpRequest".equals(observed.headers().get("x-requested-with")), "play request headers must survive RuntimeNet");
            checkHeaders(observed, channel);
        }
        System.out.println("PASS primary/backup playback 302, Location and original upstream request");
    }

    private void epgCache(Map<?, ?> channel) throws Exception {
        String url = epgUrl(channel, DATE);
        long before = count("/epg");
        HttpResponse<byte[]> first = request("GET", url, null);
        HttpResponse<byte[]> second = request("GET", url, null);
        checkEpg(first, DATE);
        checkEpg(second, DATE);
        check(Arrays.equals(first.body(), second.body()) && count("/epg") == before + 1,
                "two complete proxy requests must share the author's RuntimeNet EPG cache");
        check(last("/epg").query().equals(Map.of("c", "cctv1", "serviceId", "tvcctv", "d", "20240102")),
                "EPG query must preserve the selected date");
        checkHeaders(last("/epg"), channel);
        checkEpg(request("GET", epgUrl(channel, "2024-01-03"), null), "2024-01-03");
        check(count("/epg") == before + 2 && "20240103".equals(last("/epg").query().get("d")),
                "a different EPG date must use a separate author cache entry");
        System.out.println("PASS UTF-8 EPG JSON, one upstream fetch within TTL and date isolation");
    }

    private void resetAndReload(Map<?, ?> previous) throws Exception {
        String oldPlay = playUrl(previous);
        String oldEpg = epgUrl(previous, DATE);
        rpc("/spider/reset", Map.of());
        assertRevoked(oldPlay, oldEpg);
        List<Map<?, ?>> reloaded = loadChannels();
        check(reloaded.size() == 18, "same descriptor must reload the original catalog after reset");
        Map<?, ?> fresh = reloaded.get(0);
        check(!query(playUrl(fresh)).get("token").equals(query(oldPlay).get("token")),
                "same descriptor reload must receive a new registration token");
        assertRevoked(oldPlay, oldEpg);
        HttpResponse<byte[]> playback = request("GET", playUrl(fresh), null);
        check(playback.statusCode() == 302 && playback.headers().firstValue("Location").orElse("").equals(mediaUrl()),
                "new token must resolve playback through a fresh Python child");
        checkEpg(request("GET", epgUrl(fresh, DATE), null), DATE);
        System.out.println("PASS reset revokes old play/EPG tokens and same-descriptor reload works");
    }

    private void assertRevoked(String play, String epg) throws Exception {
        int before = requests.size();
        check(request("GET", play, null).statusCode() == 404 && request("GET", epg, null).statusCode() == 404,
                "retired playback and EPG URLs must stay 404");
        check(requests.size() == before, "retired tokens must not restart or invoke the author script");
    }

    private void checkHeaders(UpstreamRequest observed, Map<?, ?> channel) {
        check((upstreamOrigin + "/").equals(observed.headers().get("referer")), "original Referer must reach upstream");
        check(channel.get("ua").equals(observed.headers().get("user-agent")), "original User-Agent must reach upstream");
    }

    private void checkProxyOrigin(String url) {
        URI uri = URI.create(url);
        check((uri.getScheme() + "://" + uri.getRawAuthority()).equals(bridgeOrigin)
                && "/script-proxy".equals(uri.getPath()), "author must use the same loopback port as SpiderServer RPC");
    }

    private static void checkEpg(HttpResponse<byte[]> result, String date) {
        check(result.statusCode() == 200 && result.headers().firstValue("Content-Type").orElse("").equals("application/json"),
                "author three-tuple EPG response must preserve status and MIME");
        check(JsonCodec.parseObject(text(result)).equals(Map.of("date", date, "epg_data", List.of(
                Map.of("title", "早间新闻", "start", "08:00:00", "end", "08:30:00")))),
                "EPG UTF-8 body and author timezone conversion must survive the complete bridge");
    }

    private void serveUpstream(HttpExchange exchange) throws IOException {
        try {
            Map<String, String> headers = new LinkedHashMap<>();
            exchange.getRequestHeaders().forEach((name, values) -> headers.put(name.toLowerCase(Locale.ROOT), String.join(",", values)));
            String path = exchange.getRequestURI().getPath();
            requests.add(new UpstreamRequest(path, query(exchange.getRequestURI().toString()), headers));
            String mime = "application/json; charset=utf-8";
            int status = 200;
            String body;
            switch (path) {
                case "/catalog":
                    mime = "text/html; charset=utf-8";
                    StringBuilder html = new StringBuilder("<html><head><meta charset='utf-8'></head><body>");
                    List<String> ids = channelIds();
                    for (int index = 0; index < ids.size(); index++) {
                        html.append("<a href='https://tv.cctv.com/live/").append(ids.get(index)).append("/'>频道 ")
                                .append(index + 1).append("</a>");
                    }
                    body = html.append("<a href='https://tv.cctv.com/live/cctv1/'>重复</a>")
                            .append("<a href='https://example.invalid/ignored/'>无关链接</a></body></html>").toString();
                    break;
                case "/play":
                    body = JsonCodec.stringify(Map.of("ack", "yes", manifestField, Map.of("hls_cdrm", mediaUrl())));
                    break;
                case "/epg":
                    body = JsonCodec.stringify(Map.of("data", Map.of("cctv1", Map.of("list", List.of(
                            Map.of("title", "  早间新闻  ", "startTime", 1704153600L, "endTime", 1704155400L))))));
                    break;
                default:
                    status = 404;
                    mime = "text/plain; charset=utf-8";
                    body = "fixture route not found";
            }
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", mime);
            exchange.sendResponseHeaders(status, bytes.length);
            exchange.getResponseBody().write(bytes);
        } finally {
            exchange.close();
        }
    }

    private Map<String, Object> rpc(String route, Map<String, Object> body) throws Exception {
        HttpResponse<byte[]> response = request("POST", bridgeOrigin + route, JsonCodec.stringify(body));
        check(response.statusCode() == 200, route + " HTTP " + response.statusCode() + ": " + text(response));
        Map<String, Object> envelope = JsonCodec.parseObject(text(response));
        check(envelope.get("code") instanceof Number && ((Number) envelope.get("code")).intValue() == 0,
                route + " must return a successful RPC envelope: " + text(response));
        return envelope;
    }

    private static HttpResponse<byte[]> request(String method, String url, String body) throws Exception {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(15))
                .header("Content-Type", "application/json; charset=utf-8")
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body))
                .build(), HttpResponse.BodyHandlers.ofByteArray());
    }

    private String mediaUrl() { return upstreamOrigin + "/media/live.m3u8?token=a%2Bb&channel=cctv1"; }
    private long count(String path) { return requests.stream().filter(request -> request.path().equals(path)).count(); }
    private UpstreamRequest last(String path) {
        List<UpstreamRequest> matching = requests.stream().filter(request -> request.path().equals(path)).toList();
        check(!matching.isEmpty(), "expected upstream request " + path);
        return matching.get(matching.size() - 1);
    }
    private static List<String> channelIds() {
        List<String> ids = new ArrayList<>();
        for (int number = 1; number <= 17; number++) ids.add("cctv" + number);
        ids.add("cctv5plus");
        return ids;
    }
    private static String playUrl(Map<?, ?> channel) {
        List<?> urls = list(channel.get("urls"), "channel.urls must remain an array");
        check(urls.size() == 1, "author must produce one proxy playback URL per channel");
        return string(urls.get(0), "play URL");
    }
    private static String epgUrl(Map<?, ?> channel, String date) { return string(channel.get("epg"), "EPG template").replace("{date}", date); }
    private static Map<String, String> query(String url) {
        Map<String, String> values = new LinkedHashMap<>();
        String raw = URI.create(url).getRawQuery();
        if (raw == null || raw.isEmpty()) return values;
        for (String part : raw.split("&")) {
            String[] pair = part.split("=", 2);
            String key = URLDecoder.decode(pair[0], StandardCharsets.UTF_8);
            String value = URLDecoder.decode(pair.length > 1 ? pair[1] : "", StandardCharsets.UTF_8);
            check(values.putIfAbsent(key, value) == null, "query must not duplicate " + key);
        }
        return values;
    }
    private static String text(HttpResponse<byte[]> response) { return new String(response.body(), StandardCharsets.UTF_8); }
    private static List<?> list(Object value, String message) { check(value instanceof List, message); return (List<?>) value; }
    private static Map<?, ?> object(Object value, String message) { check(value instanceof Map, message); return (Map<?, ?>) value; }
    private static String string(Object value, String message) { check(value instanceof String, message); return (String) value; }
    private static byte[] digest(Path source) throws Exception { return MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(source)); }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private record UpstreamRequest(String path, Map<String, String> query, Map<String, String> headers) {}

    @Override
    public void close() throws Exception {
        try {
            if (bridge != null) bridge.stop();
        } finally {
            if (upstream != null) upstream.stop(0);
            if (previousHome == null) System.clearProperty("user.home");
            else System.setProperty("user.home", previousHome);
            check(root.isAbsolute() && root.getFileName().toString().startsWith("xiugou-author-cctv-"),
                    "cleanup must remain inside this generated test root");
            try (Stream<Path> files = Files.walk(root)) {
                for (Path file : (Iterable<Path>) files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(file);
            }
        }
    }
}
