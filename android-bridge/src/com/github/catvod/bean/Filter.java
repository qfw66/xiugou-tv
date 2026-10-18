package com.github.catvod.bean;

import java.util.List;

public class Filter {
    private String key;
    private String name;
    private List<Value> value;

    public Filter(String key, String name, List<Value> value) {
        this.key = key;
        this.name = name;
        this.value = value;
    }

    public String getKey() { return key; }
    public String getName() { return name; }
    public List<Value> getValue() { return value; }

    public static class Value {
        private String n;
        private String v;

        public Value(String n, String v) {
            this.n = n;
            this.v = v;
        }

        public String getN() { return n; }
        public String getV() { return v; }

        public String toJson() {
            return "{\"n\":\"" + escape(n) + "\",\"v\":\"" + escape(v) + "\"}";
        }
    }

    public String toJson() {
        StringBuilder sb = new StringBuilder("{");
        sb.append("\"key\":\"").append(escape(key)).append("\",");
        sb.append("\"name\":\"").append(escape(name)).append("\",");
        sb.append("\"value\":[");
        if (value != null) {
            for (int i = 0; i < value.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(value.get(i).toJson());
            }
        }
        sb.append("]}");
        return sb.toString();
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }
}
