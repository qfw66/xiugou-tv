package com.fongmi.companion;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.Socket;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.zip.GZIPInputStream;
import java.util.zip.InflaterInputStream;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509ExtendedTrustManager;

/**
 * drpy2 的宿主函数（TVBox QuickJS 宿主的 {@code req / pdfh / pdfa / pd / pdfl / joinUrl / local}），
 * 供 GraalJS 以 {@code __drpy.xxx(...)} 调用。复杂值一律以 JSON 字符串往返，不在 Java 侧持有 JS 对象。
 *
 * <p>{@code req(url, obj)} 语义对齐 FongMi：
 * <ul>
 *   <li>{@code obj.data} + {@code postType}（缺省 json；form 为 urlencoded）组请求体；否则 {@code obj.body} 原样发送。</li>
 *   <li>正文按请求头 Content-Type 的 charset 解码（drpy 规则靠它读 GBK 页），其次响应头 charset，最后 UTF-8。</li>
 *   <li>{@code buffer=2} 返回 base64；{@code redirect=0/false} 不跟随跳转。</li>
 *   <li>返回 {@code {code, headers, content}}，头名小写，多值时为 JSON 数组字符串。</li>
 * </ul>
 */
public final class DrpyHost {
    static final String DEFAULT_UA = "okhttp/3.12.13";

    /** 与 TVBox（okhttp 信任全部证书）一致：drpy 规则站大量是自签 / 链不全的证书。 */
    private static final SSLContext TRUST_ALL = trustAll();
    private static final ScriptHttpTransport FOLLOW =
            new ScriptHttpTransport(HttpClient.Redirect.NORMAL, TRUST_ALL);
    private static final ScriptHttpTransport NO_FOLLOW =
            new ScriptHttpTransport(HttpClient.Redirect.NEVER, TRUST_ALL);
    private static final boolean DEBUG = Boolean.getBoolean("xiugou.drpy.debug");
    private static final Object LOCAL_LOCK = new Object();

    private final String tag;
    private final File localFile;
    private final DrpyParser parser = new DrpyParser();

    public DrpyHost(String tag, File cacheDir) {
        this.tag = tag == null ? "drpy" : tag;
        this.localFile = cacheDir == null ? null : new File(new File(cacheDir, "drpy"), "local.json");
    }

    /** X509ExtendedTrustManager：普通 X509TrustManager 会被 JSSE 包一层再做主机名校验。 */
    private static SSLContext trustAll() {
        try {
            X509ExtendedTrustManager tm = new X509ExtendedTrustManager() {
                @Override public void checkClientTrusted(X509Certificate[] c, String a) {}
                @Override public void checkServerTrusted(X509Certificate[] c, String a) {}
                @Override public void checkClientTrusted(X509Certificate[] c, String a, Socket s) {}
                @Override public void checkServerTrusted(X509Certificate[] c, String a, Socket s) {}
                @Override public void checkClientTrusted(X509Certificate[] c, String a, SSLEngine e) {}
                @Override public void checkServerTrusted(X509Certificate[] c, String a, SSLEngine e) {}
                @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            };
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[]{tm}, new SecureRandom());
            return context;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    // ---------------------------------------------------------------- URL

    /**
     * 规整成 {@link URI} 能接受的 ASCII 地址（okhttp 同义）：
     * 主机里的 {@code %xx} 先解码（规则常写 {@code v.%71%71.com} 混淆），非 ASCII 主机转 IDN；
     * 其余部分的非 ASCII 与空白按 UTF-8 百分号编码，已有的 {@code %xx} 保持不动。
     */
    public static String asciiUrl(String url) {
        if (url == null) return "";
        int scheme = url.indexOf("://");
        if (scheme > 0 && url.substring(0, scheme).matches("[A-Za-z][A-Za-z0-9+.-]*")) {
            int start = scheme + 3;
            int end = start;
            while (end < url.length() && "/?#".indexOf(url.charAt(end)) < 0) end++;
            String authority = url.substring(start, end);
            int at = authority.lastIndexOf('@');
            String user = at >= 0 ? authority.substring(0, at + 1) : "";
            String hostPort = at >= 0 ? authority.substring(at + 1) : authority;
            String host = hostPort;
            String port = "";
            int colon = hostPort.lastIndexOf(':');
            if (colon >= 0 && !hostPort.startsWith("[") && hostPort.substring(colon + 1).matches("\\d*")) {
                host = hostPort.substring(0, colon);
                port = hostPort.substring(colon);
            }
            if (host.indexOf('%') >= 0) {
                try {
                    host = java.net.URLDecoder.decode(host.replace("+", "%2B"), StandardCharsets.UTF_8);
                } catch (IllegalArgumentException ignored) {
                    // 非法转义保持原样
                }
            }
            if (!host.chars().allMatch(c -> c < 0x80)) {
                try {
                    host = java.net.IDN.toASCII(host, java.net.IDN.ALLOW_UNASSIGNED);
                } catch (IllegalArgumentException ignored) {
                    // 交给下面按百分号编码
                }
            }
            return url.substring(0, start) + escape(user + host + port) + escape(url.substring(end));
        }
        return escape(url);
    }

    private static String escape(String url) {
        StringBuilder sb = new StringBuilder(url.length());
        for (int i = 0; i < url.length(); i++) {
            char c = url.charAt(i);
            if (c > 0x20 && c < 0x7f && c != '"' && c != '<' && c != '>' && c != '\\' && c != '^' && c != '`'
                    && c != '{' && c != '|' && c != '}') {
                sb.append(c);
                continue;
            }
            int cp = url.codePointAt(i);
            if (Character.charCount(cp) == 2) i++;
            for (byte b : new String(Character.toChars(cp)).getBytes(StandardCharsets.UTF_8)) {
                sb.append('%').append(String.format("%02X", b & 0xff));
            }
        }
        return sb.toString();
    }

    // ---------------------------------------------------------------- HTTP

    public String req(String url, String optionsJson) {
        Map<String, Object> options = JsonCodec.parseObject(optionsJson == null ? "{}" : optionsJson);
        Map<String, Object> result = new LinkedHashMap<>();
        try {
            String verb = str(options.get("method")).toUpperCase(Locale.ROOT);
            if (verb.isEmpty()) verb = "GET";
            Map<String, String> headers = new LinkedHashMap<>();
            if (options.get("headers") instanceof Map<?, ?> raw) {
                for (Map.Entry<?, ?> e : raw.entrySet()) {
                    String name = String.valueOf(e.getKey()).trim();
                    if (!name.isEmpty() && e.getValue() != null) headers.put(name, String.valueOf(e.getValue()));
                }
            }
            String contentType = header(headers, "Content-Type");
            Charset reqCharset = charsetOrNull(contentType);
            byte[] body = null;
            Object data = options.get("data");
            String postType = str(options.get("postType")).toLowerCase(Locale.ROOT);
            if (data != null && !"GET".equals(verb)) {
                Charset cs = reqCharset == null ? StandardCharsets.UTF_8 : reqCharset;
                if (postType.startsWith("form")) {
                    body = formEncode(data, cs).getBytes(StandardCharsets.US_ASCII);
                    if (contentType == null) contentType = "application/x-www-form-urlencoded";
                } else {
                    body = (data instanceof String s ? s : JsonCodec.stringify(data)).getBytes(cs);
                    if (contentType == null) contentType = "application/json";
                }
            } else if (options.get("body") != null && !"GET".equals(verb)) {
                Object raw = options.get("body");
                Charset cs = reqCharset == null ? StandardCharsets.UTF_8 : reqCharset;
                body = (raw instanceof String s ? s : JsonCodec.stringify(raw)).getBytes(cs);
                if (contentType == null) contentType = "application/x-www-form-urlencoded";
            }
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(asciiUrl(url.trim())))
                    .timeout(Duration.ofMillis(timeout(options.get("timeout"))));
            boolean hasUa = false;
            for (Map.Entry<String, String> e : headers.entrySet()) {
                if (e.getKey().equalsIgnoreCase("Content-Type")) continue;
                try {
                    builder.setHeader(e.getKey(), e.getValue());
                    if (e.getKey().equalsIgnoreCase("User-Agent")) hasUa = true;
                } catch (IllegalArgumentException restricted) {
                    // Host / Connection / Content-Length 由 HttpClient 自己管
                }
            }
            if (!hasUa) builder.setHeader("User-Agent", DEFAULT_UA);
            if (contentType != null && (body != null || headers.keySet().stream().anyMatch(k -> k.equalsIgnoreCase("Content-Type")))) {
                builder.setHeader("Content-Type", contentType);
            }
            builder.method(verb, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofByteArray(body));
            Object redirect = options.get("redirect");
            boolean follow = !(Boolean.FALSE.equals(redirect) || redirect instanceof Number n && n.intValue() == 0
                    || "0".equals(String.valueOf(redirect)) || "false".equals(String.valueOf(redirect)));
            HttpResponse<InputStream> response = (follow ? FOLLOW : NO_FOLLOW)
                    .send(builder.build());
            byte[] bytes;
            try (InputStream in = response.body()) {
                bytes = HttpBridge.readCapped(in);
            }
            bytes = decompress(bytes, response.headers().firstValue("content-encoding").orElse(""));
            Map<String, Object> outHeaders = new LinkedHashMap<>();
            response.headers().map().forEach((key, values) -> {
                if (key == null || key.startsWith(":") || values.isEmpty()) return;
                String name = key.toLowerCase(Locale.ROOT);
                outHeaders.put(name, values.size() == 1 ? values.get(0) : JsonCodec.stringify(new ArrayList<>(values)));
            });
            int buffer = (int) number(options.get("buffer"));
            Object content;
            if (buffer == 2) {
                content = Base64.getEncoder().encodeToString(bytes);
            } else if (buffer == 1) {
                List<Integer> list = new ArrayList<>(bytes.length);
                for (byte b : bytes) list.add(b & 0xff);
                content = list;
            } else {
                Charset cs = reqCharset != null ? reqCharset
                        : charsetOrNull(response.headers().firstValue("content-type").orElse(null));
                content = new String(bytes, cs == null ? StandardCharsets.UTF_8 : cs);
            }
            result.put("code", response.statusCode());
            result.put("headers", outHeaders);
            result.put("content", content);
            if (DEBUG) log(verb + " " + url + " -> " + response.statusCode() + " len=" + bytes.length);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            fail(result, url, "请求被取消");
        } catch (Exception error) {
            fail(result, url, error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage());
        }
        return JsonCodec.stringify(result);
    }

    private void fail(Map<String, Object> result, String url, String message) {
        result.put("code", 0);
        result.put("headers", new LinkedHashMap<>());
        result.put("content", "");
        log("req 失败 " + url + " " + message);
    }

    private static String formEncode(Object data, Charset cs) {
        if (data instanceof String s) return s;
        if (!(data instanceof Map<?, ?> map)) return "";
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<?, ?> e : map.entrySet()) {
            if (sb.length() > 0) sb.append('&');
            Object v = e.getValue();
            String value = v == null ? "" : v instanceof String s ? s : v instanceof Number ? str(v) : JsonCodec.stringify(v);
            sb.append(URLEncoder.encode(String.valueOf(e.getKey()), cs)).append('=').append(URLEncoder.encode(value, cs));
        }
        return sb.toString();
    }

    private static String header(Map<String, String> headers, String name) {
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if (e.getKey().equalsIgnoreCase(name)) return e.getValue();
        }
        return null;
    }

    static Charset charsetOrNull(String contentType) {
        if (contentType == null) return null;
        for (String part : contentType.split(";")) {
            String p = part.trim();
            if (p.toLowerCase(Locale.ROOT).startsWith("charset=")) {
                try {
                    return Charset.forName(p.substring(8).replace("\"", "").trim());
                } catch (Exception ignored) {
                    return null;
                }
            }
        }
        return null;
    }

    private static long timeout(Object value) {
        long ms = (long) number(value);
        return ms <= 0 ? 15_000 : Math.max(1_000, ms);
    }

    private static double number(Object value) {
        if (value instanceof Number n) return n.doubleValue();
        if (value instanceof Boolean b) return b ? 1 : 0;
        try {
            return value == null ? 0 : Double.parseDouble(String.valueOf(value));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static byte[] decompress(byte[] bytes, String encoding) throws IOException {
        String enc = encoding.toLowerCase(Locale.ROOT).trim();
        if (bytes.length == 0) return bytes;
        if (enc.contains("gzip")) {
            try (InputStream in = new GZIPInputStream(new ByteArrayInputStream(bytes))) {
                return HttpBridge.readCapped(in);
            }
        }
        if (enc.contains("deflate")) {
            try (InputStream in = new InflaterInputStream(new ByteArrayInputStream(bytes))) {
                return HttpBridge.readCapped(in);
            }
        }
        return bytes;
    }

    // ---------------------------------------------------------------- 解析

    public String pdfh(String html, String rule) {
        return parser.pdfh(html, rule);
    }

    public String pd(String html, String rule, String baseUrl) {
        return parser.pd(html, rule, baseUrl);
    }

    /** @return JSON 数组字符串 */
    public String pdfa(String html, String rule) {
        return JsonCodec.stringify(parser.pdfa(html, rule));
    }

    /** @return JSON 数组字符串 */
    public String pdfl(String html, String rule, String textRule, String urlRule, String urlKey) {
        return JsonCodec.stringify(parser.pdfl(html, rule, textRule, urlRule, urlKey));
    }

    public String joinUrl(String parent, String child) {
        return parser.joinUrl(parent, child);
    }

    // ---------------------------------------------------------------- local

    public String localGet(String rule, String key) {
        synchronized (LOCAL_LOCK) {
            Object bucket = readLocal().get(rule);
            Object value = bucket instanceof Map<?, ?> m ? m.get(key) : null;
            return value == null ? "" : String.valueOf(value);
        }
    }

    public void localSet(String rule, String key, String value) {
        synchronized (LOCAL_LOCK) {
            Map<String, Object> all = readLocal();
            Map<String, Object> bucket = new LinkedHashMap<>();
            if (all.get(rule) instanceof Map<?, ?> m) m.forEach((k, v) -> bucket.put(String.valueOf(k), v));
            bucket.put(key, value == null ? "" : value);
            all.put(rule, bucket);
            writeLocal(all);
        }
    }

    public void localDelete(String rule, String key) {
        synchronized (LOCAL_LOCK) {
            Map<String, Object> all = readLocal();
            if (all.get(rule) instanceof Map<?, ?> m) {
                Map<String, Object> bucket = new LinkedHashMap<>();
                m.forEach((k, v) -> bucket.put(String.valueOf(k), v));
                bucket.remove(key);
                all.put(rule, bucket);
                writeLocal(all);
            }
        }
    }

    private Map<String, Object> memoryLocal;

    private Map<String, Object> readLocal() {
        if (localFile == null) {
            if (memoryLocal == null) memoryLocal = new LinkedHashMap<>();
            return memoryLocal;
        }
        try {
            if (!localFile.isFile()) return new LinkedHashMap<>();
            return new LinkedHashMap<>(JsonCodec.parseObject(Files.readString(localFile.toPath(), StandardCharsets.UTF_8)));
        } catch (Exception e) {
            return new LinkedHashMap<>();
        }
    }

    private void writeLocal(Map<String, Object> all) {
        if (localFile == null) {
            memoryLocal = all;
            return;
        }
        try {
            Files.createDirectories(localFile.getParentFile().toPath());
            File tmp = new File(localFile.getParentFile(), localFile.getName() + ".tmp");
            Files.writeString(tmp.toPath(), JsonCodec.stringify(all), StandardCharsets.UTF_8);
            Files.move(tmp.toPath(), localFile.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            log("local 写入失败 " + e.getMessage());
        }
    }

    // ---------------------------------------------------------------- misc

    public void log(String message) {
        System.out.println("[drpy:" + tag + "] " + message);
    }

    public String atob(String text) {
        String clean = text.replaceAll("\\s", "").replace('-', '+').replace('_', '/');
        while (clean.length() % 4 != 0) clean += "=";
        return new String(Base64.getDecoder().decode(clean), StandardCharsets.ISO_8859_1);
    }

    public String btoa(String text) {
        return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.ISO_8859_1));
    }

    private static String str(Object value) {
        if (value == null) return "";
        if (value instanceof Double d && d == Math.rint(d) && !d.isInfinite()) return String.valueOf(d.longValue());
        return String.valueOf(value);
    }
}
