package com.thegrizzlylabs.sardineandroid.impl;

import com.thegrizzlylabs.sardineandroid.DavResource;
import com.thegrizzlylabs.sardineandroid.Sardine;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.parsers.ParserConfigurationException;
import okhttp3.Credentials;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.xml.sax.SAXException;

/** 面向桌面载荷的最小 WebDAV 实现；不替代应用自己的 WebDAV 配置与账号存储。 */
public final class OkHttpSardine implements Sardine {
    private static final int MAX_DIRECTORY_BYTES = 8 * 1024 * 1024;
    private static final MediaType XML = MediaType.parse("application/xml; charset=utf-8");
    private static final String ALL_PROPERTIES = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>";
    private final OkHttpClient client = new OkHttpClient.Builder().build();
    private volatile String authorization;

    public OkHttpSardine() {
    }

    @Override
    public void setCredentials(String username, String password) {
        authorization = username == null || password == null ? null
                : Credentials.basic(username, password, StandardCharsets.UTF_8);
    }

    @Override
    public List<DavResource> list(String url) throws IOException {
        Request request = request(url).header("Depth", "1")
                .method("PROPFIND", RequestBody.create(XML, ALL_PROPERTIES)).build();
        try (Response response = execute(request)) {
            requireSuccess(response);
            ResponseBody body = response.body();
            if (body == null) throw new IOException("WebDAV PROPFIND has no response body");
            byte[] bytes = body.byteStream().readNBytes(MAX_DIRECTORY_BYTES + 1);
            if (bytes.length > MAX_DIRECTORY_BYTES) throw new IOException("WebDAV directory response is too large");
            return readResources(bytes);
        }
    }

    @Override
    public boolean exists(String url) throws IOException {
        try (Response response = execute(request(url).head().build())) {
            if (response.code() == 404) return false;
            requireSuccess(response);
            return true;
        }
    }

    @Override
    public void createDirectory(String url) throws IOException {
        try (Response response = execute(request(url).method("MKCOL", null).build())) {
            requireSuccess(response);
        }
    }

    @Override
    public void put(String url, File file, String contentType) throws IOException {
        MediaType type = MediaType.parse(contentType == null ? "application/octet-stream" : contentType);
        try (Response response = execute(request(url).put(RequestBody.create(type, file)).build())) {
            requireSuccess(response);
        }
    }

    @Override
    public InputStream get(String url) throws IOException {
        Response response = execute(request(url).get().build());
        try {
            requireSuccess(response);
            ResponseBody body = response.body();
            if (body == null) throw new IOException("WebDAV GET has no response body");
            return new FilterInputStream(body.byteStream()) {
                @Override
                public void close() throws IOException {
                    try {
                        super.close();
                    } finally {
                        response.close();
                    }
                }
            };
        } catch (IOException | RuntimeException error) {
            response.close();
            throw error;
        }
    }

    private Response execute(Request request) throws IOException {
        String credentials = authorization;
        if (credentials == null) return client.newCall(request).execute();
        HttpUrl origin = request.url();
        OkHttpClient authenticated = client.newBuilder().authenticator((route, response) -> {
            HttpUrl target = response.request().url();
            // 只回应原始服务的 Basic 挑战，重定向目标不能借 401 索取凭据。
            if (!origin.scheme().equals(target.scheme()) || !origin.host().equals(target.host())
                    || origin.port() != target.port() || response.request().header("Authorization") != null
                    || response.challenges().stream().noneMatch(c -> "Basic".equalsIgnoreCase(c.scheme()))) {
                return null;
            }
            return response.request().newBuilder().header("Authorization", credentials).build();
        }).build();
        return authenticated.newCall(request).execute();
    }

    private static Request.Builder request(String url) throws IOException {
        try {
            return new Request.Builder().url(url);
        } catch (IllegalArgumentException error) {
            throw new IOException("Invalid WebDAV URL", error);
        }
    }

    private static void requireSuccess(Response response) throws IOException {
        if (!response.isSuccessful()) throw new IOException("WebDAV " + response.request().method() + " HTTP " + response.code());
    }

    private static List<DavResource> readResources(byte[] bytes) throws IOException {
        try {
            DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
            factory.setXIncludeAware(false);
            factory.setExpandEntityReferences(false);
            DocumentBuilder builder = factory.newDocumentBuilder();
            Document document = builder.parse(new ByteArrayInputStream(bytes));
            Element root = document.getDocumentElement();
            if (!named(root, "multistatus")) throw new IOException("Expected WebDAV multistatus response");
            List<DavResource> result = new ArrayList<>();
            for (Element response : children(root, "response")) {
                List<Element> properties = new ArrayList<>();
                for (Element status : children(response, "propstat")) {
                    if (text(status, "status").matches("HTTP/\\S+ 2\\d\\d(?:\\s.*)?")) {
                        properties.addAll(children(status, "prop"));
                    }
                }
                if (properties.isEmpty()) continue;
                String href = text(response, "href");
                if (href.isEmpty()) throw new IOException("WebDAV resource is missing href");
                URI uri = URI.create(href);
                if (uri.getPath() == null) throw new IOException("WebDAV resource href has no path");
                boolean directory = false;
                long length = -1;
                Date modified = null;
                for (Element prop : properties) {
                    for (Element type : children(prop, "resourcetype")) {
                        directory |= !children(type, "collection").isEmpty();
                    }
                    directory |= "httpd/unix-directory".equals(text(prop, "getcontenttype"));
                    String size = text(prop, "getcontentlength");
                    if (!size.isEmpty()) {
                        try { length = Long.parseLong(size); }
                        catch (NumberFormatException ignored) { /* 与上游未知大小语义保持一致。 */ }
                    }
                    String date = text(prop, "getlastmodified");
                    if (!date.isEmpty()) modified = parseDate(date);
                }
                result.add(new DavResource(uri, directory, length, modified));
            }
            return result;
        } catch (ParserConfigurationException | SAXException | IllegalArgumentException error) {
            throw new IOException("Invalid WebDAV directory XML", error);
        }
    }

    private static Date parseDate(String value) {
        try {
            return Date.from(ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant());
        } catch (DateTimeParseException ignored) {
            try { return Date.from(Instant.parse(value)); }
            catch (DateTimeParseException invalid) { return null; }
        }
    }

    private static String text(Element parent, String name) {
        List<Element> matching = children(parent, name);
        return matching.isEmpty() ? "" : matching.get(0).getTextContent().trim();
    }

    private static boolean named(Element element, String name) {
        return "DAV:".equals(element.getNamespaceURI()) && name.equals(element.getLocalName());
    }

    private static List<Element> children(Element parent, String name) {
        List<Element> result = new ArrayList<>();
        for (Node child = parent.getFirstChild(); child != null; child = child.getNextSibling()) {
            if (child instanceof Element element && named(element, name)) result.add(element);
        }
        return result;
    }
}
