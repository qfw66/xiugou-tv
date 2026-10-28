package com.github.catvod.net;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.Map;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import okhttp3.Dns;
import okhttp3.OkHttpClient;

import com.github.catvod.utils.DebugLog;
import com.github.catvod.utils.HeaderOverride;

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
     *
     * <p>与 FongMi 宿主一致：不校验证书链与主机名（上游 getBuilder 的
     * {@code hostnameVerifier((h, s) -> true)} + trust-all {@code sslSocketFactory}）。
     * 载荷默认宿主会这样做，站点证书过期 / 自签时手机端照常出数据，桌面端也必须如此。
     */
    public static OkHttpClient client() {
        OkHttpClient client = CLIENT;
        if (client == null) {
            synchronized (OkHttp.class) {
                client = CLIENT;
                // 调试/伪装拦截器由构建期补丁统一注入（见 PatchOkHttp），
                // 这里不再重复添加，否则同一个请求会被记两遍（覆盖前/覆盖后各一条）。
                if (client == null) {
                    CLIENT = client = new OkHttpClient.Builder()
                            .dns(dns())
                            .hostnameVerifier((hostname, session) -> true)
                            .sslSocketFactory(TRUST_ALL_FACTORY, TRUST_ALL)
                            .build();
                }
            }
        }
        return client;
    }

    private static final X509TrustManager TRUST_ALL = new X509TrustManager() {
        @Override
        public void checkClientTrusted(X509Certificate[] chain, String authType) {
        }

        @Override
        public void checkServerTrusted(X509Certificate[] chain, String authType) {
        }

        @Override
        public X509Certificate[] getAcceptedIssuers() {
            return new X509Certificate[0];
        }
    };

    private static final SSLSocketFactory TRUST_ALL_FACTORY = trustAllContext().getSocketFactory();

    private static SSLContext trustAllContext() {
        try {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[]{TRUST_ALL}, new SecureRandom());
            return context;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
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
        headers = HeaderOverride.apply(headers);
        long dbg = DebugLog.httpEnabled() ? DebugLog.nextId() : 0;
        long started = System.nanoTime();
        DebugLog.httpRequest(dbg, method, urlStr, headers, body);
        URL url = URI.create(urlStr).toURL();
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        if (conn instanceof HttpsURLConnection) {
            HttpsURLConnection https = (HttpsURLConnection) conn;
            https.setSSLSocketFactory(TRUST_ALL_FACTORY);
            https.setHostnameVerifier((hostname, session) -> true);
        }
        try {
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
            long cost = (System.nanoTime() - started) / 1_000_000L;
            InputStream is = (code >= 200 && code < 400) ? conn.getInputStream() : conn.getErrorStream();
            if (is == null) {
                DebugLog.httpResponse(dbg, code, cost, conn.getContentType(), 0, new byte[0]);
                return new byte[0];
            }

            try (ByteArrayOutputStream baos = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[8192];
                int n;
                while ((n = is.read(buffer)) != -1) {
                    baos.write(buffer, 0, n);
                }
                byte[] out = baos.toByteArray();
                DebugLog.httpResponse(dbg, code, cost, conn.getContentType(), out.length, out);
                return out;
            } finally {
                try { is.close(); } catch (Exception ignored) {}
            }
        } catch (Throwable t) {
            DebugLog.httpError(dbg, t);
            throw t;
        } finally {
            conn.disconnect();
        }
    }
}
