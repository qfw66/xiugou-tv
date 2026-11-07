package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;

/** Binds live JSON pseudo URLs to their registered script without widening URL scheme support. */
final class PyProxyAddress {
    private PyProxyAddress() { }

    static String normalize(String json, String base, String token, String siteKey) {
        if (json == null) return null;
        Object value = JsonCodec.parse(json);
        visit(value, base, token, siteKey);
        return JsonCodec.stringify(value);
    }

    @SuppressWarnings("unchecked")
    private static void visit(Object value, String base, String token, String siteKey) {
        if (value instanceof Map) {
            Map<String, Object> map = (Map<String, Object>) value;
            for (Map.Entry<String, Object> entry : map.entrySet()) {
                Object child = entry.getValue();
                if ((entry.getKey().equals("url") || entry.getKey().equals("urls")) && child instanceof String) {
                    entry.setValue(address((String) child, base, token, siteKey));
                } else if (entry.getKey().equals("urls") && child instanceof List) {
                    List<Object> urls = (List<Object>) child;
                    for (int i = 0; i < urls.size(); i++) {
                        Object url = urls.get(i);
                        if (url instanceof String) urls.set(i, address((String) url, base, token, siteKey));
                        else visit(url, base, token, siteKey);
                    }
                } else {
                    visit(child, base, token, siteKey);
                }
            }
        } else if (value instanceof List) {
            for (Object child : (List<?>) value) visit(child, base, token, siteKey);
        }
    }

    private static String address(String value, String base, String token, String siteKey) {
        if (!value.startsWith("proxy://")) return value;
        if (base.isEmpty()) throw invalid();
        int labelIndex = value.indexOf('$');
        String label = labelIndex < 0 ? "" : value.substring(labelIndex);
        String raw = value.substring(8, labelIndex < 0 ? value.length() : labelIndex);
        if (raw.isEmpty() || raw.startsWith("?") || raw.indexOf('#') >= 0) throw invalid();
        Map<String, String> params = new LinkedHashMap<>();
        for (String pair : raw.split("&", -1)) {
            String[] parts = pair.split("=", 2);
            if (parts.length != 2) throw invalid();
            String key;
            String content;
            try {
                key = URLDecoder.decode(parts[0], StandardCharsets.UTF_8);
                content = URLDecoder.decode(parts[1], StandardCharsets.UTF_8);
            } catch (IllegalArgumentException error) { throw invalid(); }
            if (key.isEmpty() || params.putIfAbsent(key, content) != null) throw invalid();
        }
        Map<String, String> routing = Map.of("token", token, "do", "py", "siteKey", siteKey);
        for (Map.Entry<String, String> entry : routing.entrySet()) {
            String previous = params.remove(entry.getKey());
            if (previous != null && !previous.equals(entry.getValue())) throw invalid();
        }
        StringBuilder target = new StringBuilder(base).append("&do=py&siteKey=").append(encode(siteKey));
        for (Map.Entry<String, String> entry : params.entrySet()) {
            target.append('&').append(encode(entry.getKey())).append('=').append(encode(entry.getValue()));
        }
        return target.append(label).toString();
    }

    private static String encode(String value) { return URLEncoder.encode(value, StandardCharsets.UTF_8); }
    private static IllegalArgumentException invalid() { return new IllegalArgumentException("invalid script proxy address"); }
}
