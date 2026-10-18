package com.github.catvod.utils;

import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.regex.Pattern;

public class Util {
    public static final String CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
    public static final Pattern THUNDER = Pattern.compile("^(magnet|thunder|ed2k):.*");
    public static final List<String> MEDIA = Arrays.asList("mp4", "mkv", "mov", "wav", "wma", "wmv", "flv", "avi", "iso", "mpg", "ts", "mp3", "aac", "flac", "m4a", "ape", "ogg", "rm", "rmvb", "asf", "dts", "dsf", "dff", "m3u8");
    public static final List<String> SUB = Arrays.asList("srt", "ass", "ssa", "vtt");

    public static boolean isThunder(String url) {
        if (url == null) return false;
        return THUNDER.matcher(url).find() || url.endsWith(".torrent");
    }

    public static boolean isSub(String text) {
        return text != null && SUB.contains(getExt(text).toLowerCase());
    }

    public static boolean isMedia(String text) {
        return text != null && MEDIA.contains(getExt(text).toLowerCase());
    }

    public static String getExt(String name) {
        if (name == null) return "";
        int dot = name.lastIndexOf(".");
        return dot != -1 ? name.substring(dot + 1).toLowerCase() : name.toLowerCase();
    }

    public static String removeExt(String text) {
        if (text == null) return "";
        int dot = text.lastIndexOf(".");
        return dot != -1 ? text.substring(0, dot) : text;
    }

    public static String encode(String s) {
        try {
            return URLEncoder.encode(s, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return s;
        }
    }

    public static String decode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return s;
        }
    }
}
