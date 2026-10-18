package com.fongmi.companion;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Small dependency-free JSON parser/stringifier for RPC payloads and JS bridge values. */
public final class JsonCodec {
    private JsonCodec() {}

    public static Object parse(String json) {
        if (json == null) return null;
        return new Parser(json).parseValue();
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> parseObject(String json) {
        Object value = parse(json);
        return value instanceof Map ? (Map<String, Object>) value : new LinkedHashMap<>();
    }

    public static String stringify(Object value) {
        StringBuilder out = new StringBuilder();
        write(value, out);
        return out.toString();
    }

    private static void write(Object value, StringBuilder out) {
        if (value == null) { out.append("null"); return; }
        if (value instanceof String || value instanceof Character) {
            out.append('"').append(escape(String.valueOf(value))).append('"'); return;
        }
        if (value instanceof Number || value instanceof Boolean) { out.append(value); return; }
        if (value instanceof Map) {
            out.append('{');
            boolean first = true;
            for (Object raw : ((Map<?, ?>) value).entrySet()) {
                Map.Entry<?, ?> entry = (Map.Entry<?, ?>) raw;
                if (!first) out.append(',');
                first = false;
                write(String.valueOf(entry.getKey()), out);
                out.append(':');
                write(entry.getValue(), out);
            }
            out.append('}'); return;
        }
        if (value instanceof Iterable) {
            out.append('['); boolean first = true;
            for (Object item : (Iterable<?>) value) {
                if (!first) out.append(',');
                first = false; write(item, out);
            }
            out.append(']'); return;
        }
        if (value.getClass().isArray()) {
            out.append('['); int length = java.lang.reflect.Array.getLength(value);
            for (int i = 0; i < length; i++) { if (i > 0) out.append(','); write(java.lang.reflect.Array.get(value, i), out); }
            out.append(']'); return;
        }
        write(String.valueOf(value), out);
    }

    public static String escape(String value) {
        if (value == null) return "";
        StringBuilder out = new StringBuilder(value.length() + 16);
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '\\': out.append("\\\\"); break;
                case '"': out.append("\\\""); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                case '\b': out.append("\\b"); break;
                case '\f': out.append("\\f"); break;
                default:
                    if (c < 0x20) out.append(String.format("\\u%04x", (int) c)); else out.append(c);
            }
        }
        return out.toString();
    }

    private static final class Parser {
        private final String text; private int index;
        Parser(String text) { this.text = text; }
        Object parseValue() {
            skip(); if (index >= text.length()) return null;
            char c = text.charAt(index);
            if (c == '{') return parseObjectValue();
            if (c == '[') return parseArray();
            if (c == '"') return parseString();
            if (text.startsWith("true", index)) { index += 4; return true; }
            if (text.startsWith("false", index)) { index += 5; return false; }
            if (text.startsWith("null", index)) { index += 4; return null; }
            return parseNumberOrBare();
        }
        private Map<String, Object> parseObjectValue() {
            Map<String, Object> result = new LinkedHashMap<>(); index++; skip();
            while (index < text.length() && text.charAt(index) != '}') {
                String key = parseString(); skip(); if (index < text.length() && text.charAt(index) == ':') index++;
                result.put(key, parseValue()); skip();
                if (index < text.length() && text.charAt(index) == ',') { index++; skip(); } else break;
            }
            if (index < text.length() && text.charAt(index) == '}') index++;
            return result;
        }
        private List<Object> parseArray() {
            List<Object> result = new ArrayList<>(); index++; skip();
            while (index < text.length() && text.charAt(index) != ']') {
                result.add(parseValue()); skip();
                if (index < text.length() && text.charAt(index) == ',') { index++; skip(); } else break;
            }
            if (index < text.length() && text.charAt(index) == ']') index++;
            return result;
        }
        private String parseString() {
            if (index >= text.length() || text.charAt(index) != '"') return "";
            index++; StringBuilder out = new StringBuilder();
            while (index < text.length()) {
                char c = text.charAt(index++); if (c == '"') break;
                if (c != '\\' || index >= text.length()) { out.append(c); continue; }
                char e = text.charAt(index++);
                switch (e) { case 'n': out.append('\n'); break; case 'r': out.append('\r'); break; case 't': out.append('\t'); break; case 'b': out.append('\b'); break; case 'f': out.append('\f'); break; case 'u': if (index + 4 <= text.length()) { out.append((char) Integer.parseInt(text.substring(index, index + 4), 16)); index += 4; } break; default: out.append(e); }
            }
            return out.toString();
        }
        private Object parseNumberOrBare() {
            int start = index; while (index < text.length() && ",]} \t\r\n".indexOf(text.charAt(index)) < 0) index++;
            String value = text.substring(start, index);
            try { if (value.contains(".") || value.contains("e") || value.contains("E")) return Double.parseDouble(value); return Long.parseLong(value); }
            catch (NumberFormatException ignored) { return value; }
        }
        private void skip() { while (index < text.length() && Character.isWhitespace(text.charAt(index))) index++; }
    }
}
