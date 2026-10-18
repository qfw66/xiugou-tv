package com.github.catvod.bean;

public class Sub {
    private String name;
    private String ext;
    private String url;

    public static Sub create() {
        return new Sub();
    }

    public Sub name(String name) {
        this.name = name;
        return this;
    }

    public Sub ext(String ext) {
        this.ext = ext;
        return this;
    }

    public Sub url(String url) {
        this.url = url;
        return this;
    }

    public String getName() { return name; }
    public String getExt() { return ext; }
    public String getUrl() { return url; }

    public String toJson() {
        return "{\"name\":\"" + escape(name) + "\",\"ext\":\"" + escape(ext) + "\",\"url\":\"" + escape(url) + "\"}";
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }
}
