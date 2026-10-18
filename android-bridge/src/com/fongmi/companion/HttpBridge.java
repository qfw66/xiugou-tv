package com.fongmi.companion;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

/** Synchronous HTTP bridge exposed to the JavaScript source adapter. */
public final class HttpBridge {
    private final HttpClient client = HttpClient.newBuilder()
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
            HttpResponse<String> response = client.send(builder.build(), HttpResponse.BodyHandlers.ofString());
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("ok", response.statusCode() >= 200 && response.statusCode() < 400);
            result.put("status", response.statusCode());
            result.put("url", response.uri().toString());
            result.put("content", response.body());
            result.put("text", response.body());
            Map<String, Object> headers = new LinkedHashMap<>();
            response.headers().map().forEach((key, values) -> headers.put(key, values.size() == 1 ? values.get(0) : values));
            result.put("headers", headers);
            return JsonCodec.stringify(result);
        } catch (Exception error) {
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("ok", false);
            result.put("status", 500);
            result.put("url", url);
            result.put("content", "");
            result.put("text", "");
            result.put("error", error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage());
            result.put("headers", new LinkedHashMap<>());
            return JsonCodec.stringify(result);
        }
    }

    private static int number(Object value, int fallback) {
        try {
            return value == null ? fallback : Integer.parseInt(String.valueOf(value));
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }
}
