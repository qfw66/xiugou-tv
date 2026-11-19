package com.fongmi.companion;

import android.content.Context;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.Net;
import com.github.catvod.net.NetOptions;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;

/** PHP DZ BaseSpider adapter. Only explicitly dispatched Spider sources reach this factory. */
public final class PhpSpider extends Spider {
    private final String api, defaultExt, identity;
    private final File cache;
    private volatile PhpRuntime runtime;
    private volatile boolean destroyed;
    private String ext;

    public PhpSpider(String api, String ext, File cache, String key) {
        this.api = api.trim(); this.defaultExt = ext == null ? "" : ext; this.cache = cache;
        this.identity = JsonCodec.stringify(List.of(key, this.api, this.defaultExt));
    }

    public static boolean isPhpApi(String api) { return PhpSource.matches(api); }

    /** PHP source URLs may carry drpy-node's pwd query; never include it in loader diagnostics. */
    public static String diagnosticApi(String api) {
        return isPhpApi(api) ? api.split("[?#]", 2)[0] : api;
    }

    @Override public void init(Context context, String extend) throws Exception {
        ext = extend == null || extend.isEmpty() ? defaultExt : extend;
        Path source = PhpSource.prepare(api, identity, cache);
        PhpRuntime prepared = new PhpRuntime(source);
        synchronized (this) {
            if (destroyed || Thread.currentThread().isInterrupted()) { prepared.close(); throw new IOException("PHP 源已释放"); }
            runtime = prepared;
        }
        call("init", ext);
    }

    private Object call(String method, Object... args) throws Exception {
        PhpRuntime current = runtime;
        if (destroyed || current == null) throw new IOException("PHP 源未就绪或已释放");
        Map<String, Object> env = new LinkedHashMap<>();
        env.put("ext", ext);
        env.put("proxyUrl", proxyUrl(Map.of("do", "php")));
        env.put("mediaProxyUrl", proxyUrl(Map.of()));
        env.put("proxyPath", "");
        return current.call(method, env, args);
    }

    private String json(String method, Object... args) throws Exception {
        Object result = call(method, args);
        return result == null ? null : result instanceof String text ? text : JsonCodec.stringify(result);
    }

    @Override public String homeContent(boolean filter) throws Exception { return json("homeContent", filter); }
    @Override public String homeVideoContent() throws Exception { return json("homeVideoContent"); }
    @Override public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        return json("categoryContent", tid, pg, filter, extend);
    }
    @Override public String detailContent(List<String> ids) throws Exception { return json("detailContent", ids); }
    @Override public String searchContent(String key, boolean quick) throws Exception { return searchContent(key, quick, "1"); }
    @Override public String searchContent(String key, boolean quick, String pg) throws Exception { return json("searchContent", key, quick, pg); }
    @Override public String playerContent(String flag, String id, List<String> flags) throws Exception { return json("playerContent", flag, id, flags); }
    @Override public String liveContent(String url) throws Exception { return json("liveContent", url); }
    @Override public String action(String action) throws Exception { return json("action", action, ""); }

    @Override public Object[] proxy(Map<String, String> params) throws Exception {
        String method = params.getOrDefault("method", "GET");
        if (!method.equals("GET") && !method.equals("HEAD")) return new Object[]{405, "text/plain", "method not allowed"};
        // BaseSpider.proxyMediaUrl() targets the capability URL without the source's do=php marker.
        if (!params.containsKey("do") && "base64".equals(params.get("form")) && "1".equals(params.get("stream"))) {
            String url = decode(params.get("url"));
            Map<String, String> headers = params.containsKey("header") ? headers(JsonCodec.parse(decode(params.get("header")))) : new LinkedHashMap<>();
            return stream(url, headers, params);
        }
        Map<String, String> query = new LinkedHashMap<>(params);
        query.put("__range", params.getOrDefault("range", ""));
        query.put("__mediaProxy", proxyUrl(Map.of()));
        Object result = call("localProxy", query);
        if (result instanceof String text) result = JsonCodec.parse(text);
        if (!(result instanceof List<?> tuple) || tuple.size() < 3 || !(tuple.get(0) instanceof Number status)) {
            throw new IOException("PHP localProxy 返回值格式无效");
        }
        String mime = Objects.toString(tuple.get(1), "application/octet-stream");
        Object body = tuple.get(2);
        Map<String, String> headers = tuple.size() > 3 ? headers(tuple.get(3)) : new LinkedHashMap<>();
        int mode = tuple.size() > 4 && tuple.get(4) instanceof Number number ? number.intValue() : 0;
        if (mode == 2 || mode == 3) return stream(Objects.toString(body, ""), headers, params);
        if (mode == 1) {
            String encoded = Objects.toString(body, "");
            int prefix = encoded.indexOf("base64,");
            if (prefix >= 0) encoded = URLDecoder.decode(encoded.substring(prefix + 7).replace("+", "%2B"), StandardCharsets.UTF_8);
            body = Base64.getMimeDecoder().decode(encoded);
        } else if (mode != 0) throw new IOException("PHP localProxy toBytes 不支持");
        else if (!(body instanceof String)) body = JsonCodec.stringify(body);
        return new Object[]{status.intValue(), mime, body, headers};
    }

    private Object[] stream(String url, Map<String, String> headers, Map<String, String> params) throws Exception {
        URI uri = URI.create(url);
        if (!Set.of("http", "https").contains(uri.getScheme()) || uri.getHost() == null) throw new IOException("PHP 流式代理地址无效");
        // The nested media helper is source-owned; unwrap it rather than recursively calling this same capability.
        URI own = URI.create(proxyUrl(Map.of()));
        if (uri.getScheme().equals(own.getScheme()) && uri.getRawAuthority().equals(own.getRawAuthority()) && uri.getPath().equals(own.getPath())) {
            Map<String, String> nested = JavaProxyHandler.query(uri.getRawQuery());
            if (!"base64".equals(nested.get("form")) || !"1".equals(nested.get("stream"))) throw new IOException("PHP 代理循环");
            url = decode(nested.get("url"));
            if (nested.containsKey("header")) headers.putAll(headers(JsonCodec.parse(decode(nested.get("header")))));
            URI target = URI.create(url);
            if (!Set.of("http", "https").contains(target.getScheme()) || target.getHost() == null
                    || (Objects.equals(target.getRawAuthority(), own.getRawAuthority()) && target.getPath().equals(own.getPath()))) {
                throw new IOException("PHP 代理循环或地址无效");
            }
        }
        if (params.containsKey("range")) {
            headers.keySet().removeIf(name -> name.equalsIgnoreCase("Range"));
            headers.put("Range", params.get("range"));
        }
        NetOptions options = NetOptions.from(JsonCodec.stringify(Map.of("method", params.getOrDefault("method", "GET"),
                "headers", headers, "cookie", false, "timeout", 30_000, "streaming", true, "logMetadataOnly", true)));
        CompletableFuture<Net.StreamResult> pending = net.requestStreamAsync(url, options);
        try {
            Net.StreamResult response = pending.get(30, TimeUnit.SECONDS);
            if (destroyed) { response.close(); throw new IOException("PHP 源已释放"); }
            return new Object[]{response.code, response.contentType, response, response.headers};
        } catch (Exception error) { pending.cancel(true); throw error; }
    }

    private static Map<String, String> headers(Object value) throws IOException {
        Map<String, String> headers = new LinkedHashMap<>();
        if (value == null || value instanceof List<?> list && list.isEmpty()) return headers;
        if (!(value instanceof Map<?, ?> map)) throw new IOException("PHP 代理请求头格式无效");
        for (var item : map.entrySet()) headers.put(String.valueOf(item.getKey()), String.valueOf(item.getValue()));
        return headers;
    }

    private static String decode(String value) { return new String(Base64.getDecoder().decode(value), StandardCharsets.UTF_8); }

    @Override public void destroy() {
        PhpRuntime owned;
        synchronized (this) { destroyed = true; owned = runtime; }
        if (owned != null) owned.close();
        closeHostResources();
    }
}
