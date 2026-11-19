package com.fongmi.companion;

import org.jsoup.Jsoup;
import org.jsoup.nodes.DataNode;
import org.jsoup.nodes.Document;
import org.jsoup.nodes.Element;
import org.jsoup.nodes.Node;
import org.jsoup.nodes.TextNode;
import org.jsoup.select.Selector;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;
import java.util.zip.InflaterInputStream;
import javax.crypto.Cipher;

/**
 * XPTV 脚本宿主 API 的 Java 侧（由 {@code xptv-runtime.js} 包装成 $fetch / cheerio / JSEncrypt…）。
 *
 * <p>方法都是公开实例方法，供 GraalJS 以 {@code __xptv.xxx(...)} 调用；参数只用字符串与 jsoup 节点，
 * 不在 Java 侧持有任何 JS 对象。
 */
public final class XptvHost {
    /** 站点脚本多按 iOS 客户端写，没有 UA 的请求常被拦；脚本自己给了 UA 时不覆盖。 */
    static final String DEFAULT_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

    private static final ScriptHttpTransport FOLLOW =
            new ScriptHttpTransport(HttpClient.Redirect.NORMAL, null);
    private static final ScriptHttpTransport NO_FOLLOW =
            new ScriptHttpTransport(HttpClient.Redirect.NEVER, null);
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final boolean DEBUG = Boolean.getBoolean("xiugou.xptv.debug");
    private static final Pattern DATA_CONTAINS = Pattern.compile("((?:^|[\\s,>+~(])(?:script|style)[^\\s,>+~]*?):contains\\(");

    private final String tag;

    public XptvHost(String tag) {
        this.tag = tag == null ? "xptv" : tag;
    }

    // ---------------------------------------------------------------- HTTP

    /** @return {@code {status, url, data, headers:{name:[values]}, error?}} */
    public String fetch(String method, String url, String body, String optionsJson) {
        Map<String, Object> options = JsonCodec.parseObject(optionsJson);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("url", url);
        try {
            long timeoutMs = millis(options.get("timeout"));
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(url.trim()))
                    .timeout(Duration.ofMillis(timeoutMs));
            boolean hasUa = false;
            Object rawHeaders = options.get("headers");
            if (rawHeaders instanceof Map) {
                for (Map.Entry<?, ?> entry : ((Map<?, ?>) rawHeaders).entrySet()) {
                    String name = String.valueOf(entry.getKey()).trim();
                    if (name.isEmpty() || entry.getValue() == null) continue;
                    try {
                        builder.setHeader(name, String.valueOf(entry.getValue()));
                        if (name.equalsIgnoreCase("User-Agent")) hasUa = true;
                    } catch (IllegalArgumentException restricted) {
                        // Host / Connection / Content-Length 由 HttpClient 自己管
                    }
                }
            }
            if (!hasUa) builder.setHeader("User-Agent", DEFAULT_UA);
            String verb = method == null ? "GET" : method.toUpperCase(Locale.ROOT);
            HttpRequest.BodyPublisher publisher = body == null
                    ? HttpRequest.BodyPublishers.noBody()
                    : HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8);
            builder.method(verb, publisher);
            boolean follow = !Boolean.FALSE.equals(options.get("redirect"))
                    && !"manual".equals(String.valueOf(options.get("redirect")));
            HttpResponse<InputStream> response = (follow ? FOLLOW : NO_FOLLOW)
                    .send(builder.build());
            byte[] bytes;
            try (InputStream in = response.body()) {
                bytes = HttpBridge.readCapped(in);
            }
            bytes = decompress(bytes, response.headers().firstValue("content-encoding").orElse(""));
            Map<String, Object> headers = new LinkedHashMap<>();
            response.headers().map().forEach((key, values) -> {
                if (key != null && !key.startsWith(":")) headers.put(key, new ArrayList<>(values));
            });
            result.put("status", response.statusCode());
            result.put("url", response.uri().toString());
            result.put("data", new String(bytes, charsetOf(response.headers().firstValue("content-type").orElse(""))));
            result.put("headers", headers);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            fail(result, "请求被取消");
        } catch (Exception error) {
            fail(result, error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage());
        }
        if (DEBUG) {
            Object data = result.get("data");
            System.out.println("[xptv:" + tag + "] " + method + " " + url + " -> " + result.get("status")
                    + " len=" + (data == null ? 0 : String.valueOf(data).length())
                    + (result.get("error") == null ? "" : " error=" + result.get("error")));
        }
        return JsonCodec.stringify(result);
    }

    private static void fail(Map<String, Object> result, String message) {
        result.put("status", 0);
        result.put("data", "");
        result.put("headers", new LinkedHashMap<>());
        result.put("error", message);
    }

    /** XPTV 的 timeout 以毫秒计；缺省 20 秒，至少 1 秒。 */
    static long millis(Object value) {
        try {
            long ms = value == null ? 20_000 : (long) Double.parseDouble(String.valueOf(value));
            return ms <= 0 ? 20_000 : Math.max(1_000, ms);
        } catch (NumberFormatException e) {
            return 20_000;
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

    static Charset charsetOf(String contentType) {
        for (String part : contentType.split(";")) {
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

    // ---------------------------------------------------------------- misc

    public void log(String message) {
        System.out.println("[xptv:" + tag + "] " + message);
    }

    public int randomInt() {
        return RANDOM.nextInt();
    }

    /** 浏览器 btoa：按 Latin-1 取字节。 */
    public String btoa(String text) {
        return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.ISO_8859_1));
    }

    /** 浏览器 atob：结果为 Latin-1 字符串；容忍空白、缺省填充与 URL 安全字符。 */
    public String atob(String text) {
        String clean = text.replaceAll("\\s", "").replace('-', '+').replace('_', '/');
        while (clean.length() % 4 != 0) clean += "=";
        return new String(Base64.getDecoder().decode(clean), StandardCharsets.ISO_8859_1);
    }

    /** 解析 / 相对解析 URL，返回各部件 JSON；非法时 {@code {error:true}}。 */
    public String parseUrl(String input, String base) {
        Map<String, Object> parts = new LinkedHashMap<>();
        try {
            URI uri = base == null ? new URI(input.trim()) : new URI(base.trim()).resolve(input.trim());
            if (uri.getScheme() == null || uri.getHost() == null) throw new IllegalArgumentException("relative");
            String userInfo = uri.getRawUserInfo() == null ? "" : uri.getRawUserInfo();
            int colon = userInfo.indexOf(':');
            parts.put("protocol", uri.getScheme().toLowerCase(Locale.ROOT) + ":");
            parts.put("username", colon < 0 ? userInfo : userInfo.substring(0, colon));
            parts.put("password", colon < 0 ? "" : userInfo.substring(colon + 1));
            parts.put("hostname", uri.getHost());
            parts.put("port", uri.getPort() < 0 ? "" : String.valueOf(uri.getPort()));
            parts.put("pathname", uri.getRawPath() == null || uri.getRawPath().isEmpty() ? "/" : uri.getRawPath());
            parts.put("search", uri.getRawQuery() == null ? "" : uri.getRawQuery());
            parts.put("hash", uri.getRawFragment() == null ? "" : uri.getRawFragment());
        } catch (Exception e) {
            parts.clear();
            parts.put("error", true);
        }
        return JsonCodec.stringify(parts);
    }

    // ---------------------------------------------------------------- RSA (JSEncrypt)

    public String rsaEncrypt(String pem, String text) {
        try {
            Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
            if (pem.contains("PRIVATE")) cipher.init(Cipher.ENCRYPT_MODE, privateKey(pem));
            else cipher.init(Cipher.ENCRYPT_MODE, publicKey(pem));
            return Base64.getEncoder().encodeToString(cipher.doFinal(text.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            log("RSA encrypt failed: " + e);
            return null;
        }
    }

    public String rsaDecrypt(String pem, String base64) {
        try {
            Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
            cipher.init(Cipher.DECRYPT_MODE, privateKey(pem));
            byte[] raw = Base64.getDecoder().decode(base64.replaceAll("\\s", ""));
            return new String(cipher.doFinal(raw), StandardCharsets.UTF_8);
        } catch (Exception e) {
            log("RSA decrypt failed: " + e);
            return null;
        }
    }

    private static byte[] pemBody(String pem) {
        String body = pem.replaceAll("-----[A-Z ]+-----", "").replaceAll("\\s", "");
        return Base64.getDecoder().decode(body);
    }

    static PublicKey publicKey(String pem) throws Exception {
        byte[] der = pemBody(pem);
        if (pem.contains("BEGIN RSA PUBLIC KEY")) der = wrap(der, RSA_SPKI_PREFIX, true);
        return KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(der));
    }

    static PrivateKey privateKey(String pem) throws Exception {
        byte[] der = pemBody(pem);
        try {
            return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(der));
        } catch (Exception pkcs1) {
            // 「BEGIN RSA PRIVATE KEY」或裸 Base64 的 PKCS#1：套上 PKCS#8 外壳
            return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(wrap(der, RSA_PKCS8_PREFIX, false)));
        }
    }

    /** rsaEncryption AlgorithmIdentifier。 */
    private static final byte[] RSA_ALG = {0x30, 0x0d, 0x06, 0x09, 0x2a, (byte) 0x86, 0x48, (byte) 0x86,
            (byte) 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00};
    private static final byte[] RSA_SPKI_PREFIX = RSA_ALG;
    private static final byte[] RSA_PKCS8_PREFIX = RSA_ALG;

    /** 把 PKCS#1 公钥/私钥包成 SubjectPublicKeyInfo / PrivateKeyInfo。 */
    private static byte[] wrap(byte[] pkcs1, byte[] algorithm, boolean publicKey) {
        java.io.ByteArrayOutputStream inner = new java.io.ByteArrayOutputStream();
        if (!publicKey) inner.writeBytes(new byte[]{0x02, 0x01, 0x00});
        inner.writeBytes(algorithm);
        if (publicKey) {
            byte[] bitString = new byte[pkcs1.length + 1];
            System.arraycopy(pkcs1, 0, bitString, 1, pkcs1.length);
            inner.writeBytes(tlv(0x03, bitString));
        } else {
            inner.writeBytes(tlv(0x04, pkcs1));
        }
        return tlv(0x30, inner.toByteArray());
    }

    private static byte[] tlv(int type, byte[] value) {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        out.write(type);
        int len = value.length;
        if (len < 0x80) {
            out.write(len);
        } else if (len < 0x100) {
            out.write(0x81);
            out.write(len);
        } else if (len < 0x10000) {
            out.write(0x82);
            out.write(len >> 8);
            out.write(len & 0xff);
        } else {
            out.write(0x83);
            out.write(len >> 16);
            out.write((len >> 8) & 0xff);
            out.write(len & 0xff);
        }
        out.writeBytes(value);
        return out.toByteArray();
    }

    // ---------------------------------------------------------------- cheerio (jsoup)

    public Document parseHtml(String html) {
        Document doc = Jsoup.parse(html == null ? "" : html);
        doc.outputSettings().prettyPrint(false);
        return doc;
    }

    public List<Node> parseFragment(String html) {
        Document doc = Jsoup.parseBodyFragment(html == null ? "" : html);
        doc.outputSettings().prettyPrint(false);
        return new ArrayList<>(doc.body().childNodes());
    }

    /** jQuery 语义的 find：只找后代，不含自身；选择器非法时返回空并记日志。 */
    public List<Element> find(Object root, String css) {
        if (!(root instanceof Element)) return List.of();
        Element element = (Element) root;
        try {
            List<Element> found = new ArrayList<>(element.select(css(css)));
            found.remove(element);
            return found;
        } catch (Selector.SelectorParseException e) {
            log("不支持的选择器: " + css + " (" + e.getMessage() + ")");
            return List.of();
        }
    }

    public boolean is(Object node, String css) {
        if (!(node instanceof Element)) return false;
        try {
            return ((Element) node).is(css(css));
        } catch (Selector.SelectorParseException e) {
            return false;
        }
    }

    /** script/style 的内容是 DataNode，jQuery 的 {@code :contains} 在 jsoup 里对应 {@code :containsData}。 */
    static String css(String css) {
        return DATA_CONTAINS.matcher(css).replaceAll("$1:containsData(");
    }

    public boolean isNode(Object value) {
        return value instanceof Node;
    }

    public boolean isElement(Object value) {
        return value instanceof Element;
    }

    public boolean hasAttr(Object el, String name) {
        return el instanceof Element && ((Element) el).hasAttr(name);
    }

    public String attr(Object el, String name) {
        return el instanceof Element ? ((Element) el).attr(name) : "";
    }

    public void setAttr(Object el, String name, String value) {
        if (el instanceof Element) ((Element) el).attr(name, value);
    }

    public void removeAttr(Object el, String name) {
        if (el instanceof Element) ((Element) el).removeAttr(name);
    }

    public boolean hasClass(Object el, String name) {
        return el instanceof Element && ((Element) el).hasClass(name);
    }

    public void addClass(Object el, String name) {
        if (el instanceof Element) ((Element) el).addClass(name);
    }

    public void removeClass(Object el, String name) {
        if (el instanceof Element) ((Element) el).removeClass(name);
    }

    /** cheerio 的 text：不规整空白；script/style 取原始内容。 */
    public String text(Object node) {
        if (node instanceof TextNode) return ((TextNode) node).getWholeText();
        if (node instanceof DataNode) return ((DataNode) node).getWholeData();
        if (node instanceof Element) {
            Element el = (Element) node;
            String name = el.normalName();
            if ("script".equals(name) || "style".equals(name)) return el.data();
            return el.wholeText();
        }
        return "";
    }

    public String html(Object node) {
        if (node instanceof Element) return ((Element) node).html();
        if (node instanceof Node) return ((Node) node).outerHtml();
        return "";
    }

    public String outerHtml(Object node) {
        return node instanceof Node ? ((Node) node).outerHtml() : "";
    }

    public void setText(Object el, String value) {
        if (el instanceof Element) ((Element) el).text(value);
    }

    public void setHtml(Object el, String value) {
        if (el instanceof Element) ((Element) el).html(value);
    }

    public void empty(Object el) {
        if (el instanceof Element) ((Element) el).empty();
    }

    public void append(Object el, String html) {
        if (el instanceof Element) ((Element) el).append(html);
    }

    public List<Element> children(Object el) {
        return el instanceof Element ? new ArrayList<>(((Element) el).children()) : List.of();
    }

    public List<Node> childNodes(Object el) {
        return el instanceof Element ? new ArrayList<>(((Element) el).childNodes()) : List.of();
    }

    public Element parent(Object node) {
        if (!(node instanceof Node)) return null;
        Node parent = ((Node) node).parent();
        return parent instanceof Element ? (Element) parent : null;
    }

    public List<Element> parents(Object el) {
        return el instanceof Element ? new ArrayList<>(((Element) el).parents()) : List.of();
    }

    public Element next(Object el) {
        return el instanceof Element ? ((Element) el).nextElementSibling() : null;
    }

    public Element prev(Object el) {
        return el instanceof Element ? ((Element) el).previousElementSibling() : null;
    }

    public List<Element> nextAll(Object el) {
        return el instanceof Element ? new ArrayList<>(((Element) el).nextElementSiblings()) : List.of();
    }

    public List<Element> prevAll(Object el) {
        return el instanceof Element ? new ArrayList<>(((Element) el).previousElementSiblings()) : List.of();
    }

    public List<Element> siblings(Object el) {
        return el instanceof Element ? new ArrayList<>(((Element) el).siblingElements()) : List.of();
    }

    public Node clone(Object node) {
        return node instanceof Node ? ((Node) node).clone() : null;
    }

    public void remove(Object node) {
        if (node instanceof Node && ((Node) node).parent() != null) ((Node) node).remove();
    }

    public int elementIndex(Object el) {
        return el instanceof Element ? ((Element) el).elementSiblingIndex() : -1;
    }
}
