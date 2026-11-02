package com.fongmi.companion;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * 暴露给 JS 源适配器的同步 HTTP 桥。
 *
 * <p>资源约束（companion 默认 {@code -Xmx256m}）：
 * <ul>
 *   <li>全进程共享一个 {@link HttpClient}——每个实例自带一条 Selector 线程和连接池，按站点各建一个会随 JS 站点数增长；</li>
 *   <li>响应体按流读取并限制在 {@link #MAX_BODY_BYTES}，超限返回错误，而不是整体读入后再复制成 JSON；</li>
 *   <li>JSON 里只放一份 body（{@code content}），{@code text} 由 JS 引导代码做别名。</li>
 * </ul>
 */
public final class HttpBridge {

    /** 单个响应体上限：页面 / 接口远小于此；超出的多半是误请求到媒体文件。 */
    static final int MAX_BODY_BYTES = 16 << 20;

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NORMAL)
            .connectTimeout(Duration.ofSeconds(20))
            .build();

    public HttpBridge() {}

    public String request(String url, String optionsJson) {
        Map<String, Object> options = JsonCodec.parseObject(optionsJson);
        String method = String.valueOf(options.getOrDefault("method", "GET")).toUpperCase();
        int timeout = number(options.get("timeout"), 20);
        try {
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(Math.max(1, timeout)));
            Object rawHeaders = options.get("headers");
            if (rawHeaders instanceof Map) {
                for (Map.Entry<?, ?> entry : ((Map<?, ?>) rawHeaders).entrySet()) {
                    builder.header(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
                }
            }
            String body = String.valueOf(options.getOrDefault("body", ""));
            if ("POST".equals(method) || "PUT".equals(method) || "PATCH".equals(method)) {
                builder.method(method, HttpRequest.BodyPublishers.ofString(body));
            } else {
                builder.method(method, HttpRequest.BodyPublishers.noBody());
            }
            HttpResponse<InputStream> response = CLIENT.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream());
            String content;
            try (InputStream in = response.body()) {
                content = new String(readCapped(in), charsetOf(response));
            }
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("ok", response.statusCode() >= 200 && response.statusCode() < 400);
            result.put("status", response.statusCode());
            result.put("url", response.uri().toString());
            result.put("content", content);
            Map<String, Object> headers = new LinkedHashMap<>();
            response.headers().map().forEach((key, values) -> headers.put(key, values.size() == 1 ? values.get(0) : values));
            result.put("headers", headers);
            return JsonCodec.stringify(result);
        } catch (InterruptedException interrupted) {
            // 看门狗取消：必须恢复中断标志，否则取消被吞掉、脚本继续发下一个请求
            Thread.currentThread().interrupt();
            return error(url, "请求被取消");
        } catch (Exception error) {
            return error(url, error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage());
        }
    }

    private static String error(String url, String message) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("ok", false);
        result.put("status", 500);
        result.put("url", url);
        result.put("content", "");
        result.put("error", message);
        result.put("headers", new LinkedHashMap<>());
        return JsonCodec.stringify(result);
    }

    /** 读满响应体，超过 {@link #MAX_BODY_BYTES} 立即放弃（关闭流会中止下载）。 */
    static byte[] readCapped(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[16 * 1024];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (out.size() + n > MAX_BODY_BYTES) {
                throw new IOException("响应体超过 " + (MAX_BODY_BYTES >> 20) + " MB，已放弃");
            }
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }

    /** 与 {@code BodyHandlers.ofString()} 一致：取 Content-Type 的 charset，缺省 UTF-8。 */
    private static Charset charsetOf(HttpResponse<?> response) {
        String type = response.headers().firstValue("content-type").orElse("");
        for (String part : type.split(";")) {
            String p = part.trim();
            if (p.toLowerCase(Locale.ROOT).startsWith("charset=")) {
                try {
                    return Charset.forName(p.substring(8).replace("\"", "").trim());
                } catch (Exception ignored) {
                    break;
                }
            }
        }
        return StandardCharsets.UTF_8;
    }

    private static int number(Object value, int fallback) {
        try {
            return value == null ? fallback : Integer.parseInt(String.valueOf(value));
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }
}
