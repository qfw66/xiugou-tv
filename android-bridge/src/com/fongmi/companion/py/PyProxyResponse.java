package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Base64;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

/** Strict runner envelope with a bounded buffer or an owned streaming body. */
public final class PyProxyResponse implements AutoCloseable {
    public static final int MAX_BODY_BYTES = 4 * 1024 * 1024;
    private static final Pattern HEADER_NAME = Pattern.compile("[!#$%&'*+.^_`|~0-9A-Za-z-]+");
    public final int status;
    public final String mime;
    public final InputStream body;
    public final long contentLength;
    public final Map<String, String> headers;

    private PyProxyResponse(int status, String mime, InputStream body, long contentLength, Map<String, String> headers) {
        this.status = status;
        this.mime = mime;
        this.body = body;
        this.contentLength = contentLength;
        this.headers = Collections.unmodifiableMap(headers);
    }

    public static PyProxyResponse decode(String json) {
        return decode(json, null, () -> { });
    }

    static PyProxyResponse decode(String json, PyRuntime owner, Runnable release) {
        Map<String, Object> value = JsonCodec.parseObject(json);
        Object marker = value.get("__xiugou_proxy__");
        Object status = value.get("status");
        if (!(marker instanceof Long) || ((Long) marker) != 1L && ((Long) marker) != 2L
                || !(status instanceof Long) || (Long) status < 200L || (Long) status > 599L) {
            throw invalid();
        }
        Object mime = value.get("mime");
        if (!(mime instanceof String) || ((String) mime).isEmpty() || !((String) mime).matches("[ -~]+")) {
            throw invalid();
        }
        Object rawHeaders = value.get("headers");
        if (!(rawHeaders instanceof Map)) throw invalid();
        Map<String, String> headers = new LinkedHashMap<>();
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) rawHeaders).entrySet()) {
            if (!(entry.getKey() instanceof String) || !HEADER_NAME.matcher((String) entry.getKey()).matches()
                    || !(entry.getValue() instanceof String)) throw invalid();
            String content = (String) entry.getValue();
            for (int i = 0; i < content.length(); i++) {
                char c = content.charAt(i);
                if (c < 32 && c != '\t' || c == 127) throw invalid();
            }
            headers.put((String) entry.getKey(), content);
        }
        if ((Long) marker == 2L) {
            Object handle = value.get("streamId");
            if (owner == null || !(handle instanceof String) || !((String) handle).matches("[0-9a-f]{32}:[0-9a-f]{32}")) throw invalid();
            return new PyProxyResponse(((Long) status).intValue(), (String) mime,
                    new PyProxyStream(owner, (String) handle, release), -1, headers);
        }
        Object encoded = value.get("bodyBase64");
        if (!(encoded instanceof String) || ((String) encoded).length() > 4 * ((MAX_BODY_BYTES + 2) / 3)) {
            throw invalid();
        }
        byte[] bytes;
        try { bytes = Base64.getDecoder().decode((String) encoded); }
        catch (IllegalArgumentException error) { throw invalid(); }
        if (bytes.length > MAX_BODY_BYTES) throw invalid();
        return new PyProxyResponse(((Long) status).intValue(), (String) mime,
                new ByteArrayInputStream(bytes), bytes.length, headers);
    }

    @Override
    public void close() throws IOException { body.close(); }

    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException("invalid script proxy response");
    }
}
