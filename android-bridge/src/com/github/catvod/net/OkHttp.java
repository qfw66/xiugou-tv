package com.github.catvod.net;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;

import okhttp3.Dns;
import okhttp3.OkHttpClient;

/**
 * Standard OkHttp compatible wrapper using Java SE HttpURLConnection.
 */
public class OkHttp {

    private static volatile OkHttpClient CLIENT;
    private static volatile OkDns DNS;

    /**
     * 对齐手机端 OkHttp.dns()：全局安全 DNS（hosts 映射 + 系统解析）。
     * spider jar 通过 Spider.safeDns() 依赖本方法。
     */
    public static Dns dns() {
        OkDns dns = DNS;
        if (dns == null) {
            synchronized (OkHttp.class) {
                dns = DNS;
                if (dns == null) DNS = dns = new OkDns();
            }
        }
        return dns;
    }

    /**
     * 对齐手机端 OkHttp.client()：全局共享 OkHttpClient。
     * spider jar 通过 Spider.client() 依赖本方法。
     */
    public static OkHttpClient client() {
        OkHttpClient client = CLIENT;
        if (client == null) {
            synchronized (OkHttp.class) {
                client = CLIENT;
                if (client == null) CLIENT = client = new OkHttpClient.Builder().dns(dns()).build();
            }
        }
        return client;
    }

    public static String string(String urlStr) {
        return string(urlStr, null);
    }

    public static String string(String urlStr, Map<String, String> headers) {
        try {
            byte[] bytes = get(urlStr, headers);
            return new String(bytes, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "";
        }
    }

    public static byte[] get(String urlStr, Map<String, String> headers) throws Exception {
        return request(urlStr, "GET", null, headers);
    }

    public static String post(String urlStr, String body, Map<String, String> headers) {
        try {
            byte[] data = body != null ? body.getBytes(StandardCharsets.UTF_8) : new byte[0];
            byte[] bytes = request(urlStr, "POST", data, headers);
            return new String(bytes, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "";
        }
    }

    public static String postJson(String urlStr, String json, Map<String, String> headers) {
        try {
            if (headers == null) headers = new java.util.HashMap<>();
            headers.put("Content-Type", "application/json; charset=utf-8");
            return post(urlStr, json, headers);
        } catch (Exception e) {
            return "";
        }
    }

    public static byte[] request(String urlStr, String method, byte[] body, Map<String, String> headers) throws Exception {
        URL url = URI.create(urlStr).toURL();
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod(method);
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(20000);
        conn.setInstanceFollowRedirects(true);
        conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36");

        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                conn.setRequestProperty(entry.getKey(), entry.getValue());
            }
        }

        if (body != null && body.length > 0) {
            conn.setDoOutput(true);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(body);
                os.flush();
            }
        }

        int code = conn.getResponseCode();
        InputStream is = (code >= 200 && code < 400) ? conn.getInputStream() : conn.getErrorStream();
        if (is == null) return new byte[0];

        try (ByteArrayOutputStream baos = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int n;
            while ((n = is.read(buffer)) != -1) {
                baos.write(buffer, 0, n);
            }
            return baos.toByteArray();
        } finally {
            try { is.close(); } catch (Exception ignored) {}
            conn.disconnect();
        }
    }
}
