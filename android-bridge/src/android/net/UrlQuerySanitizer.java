package android.net;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * android.net.UrlQuerySanitizer：解析 URL 查询串取参数值（载荷用它从网盘分享链接里取 pwd 等参数）。
 *
 * <p>Android 默认的「值净化器」会去掉不安全字符；桌面端按 URL 解码后原样返回，
 * 分享码、提取码都是字母数字，结果一致。同名参数以第一次出现为准（与 Android 一致）。
 */
public class UrlQuerySanitizer {

    private final Map<String, String> entries = new LinkedHashMap<>();
    private final List<ParameterValuePair> pairs = new ArrayList<>();

    public static class ParameterValuePair {
        public final String mParameter;
        public final String mValue;

        public ParameterValuePair(String parameter, String value) {
            this.mParameter = parameter;
            this.mValue = value;
        }
    }

    public UrlQuerySanitizer() {
    }

    public UrlQuerySanitizer(String url) {
        parseUrl(url);
    }

    public void parseUrl(String url) {
        if (url == null) return;
        int q = url.indexOf('?');
        String query = q >= 0 ? url.substring(q + 1) : "";
        int hash = query.indexOf('#');
        parseQuery(hash >= 0 ? query.substring(0, hash) : query);
    }

    public void parseQuery(String query) {
        entries.clear();
        pairs.clear();
        if (query == null || query.isEmpty()) return;
        for (String part : query.split("&")) {
            if (part.isEmpty()) continue;
            int eq = part.indexOf('=');
            String name = decode(eq < 0 ? part : part.substring(0, eq));
            String value = eq < 0 ? "" : decode(part.substring(eq + 1));
            pairs.add(new ParameterValuePair(name, value));
            entries.putIfAbsent(name, value);
        }
    }

    public String getValue(String parameter) {
        return entries.get(parameter);
    }

    public boolean hasParameter(String parameter) {
        return entries.containsKey(parameter);
    }

    public Set<String> getParameterSet() {
        return entries.keySet();
    }

    public List<ParameterValuePair> getParameterList() {
        return pairs;
    }

    public void setAllowUnregisteredParamaters(boolean allowUnregisteredParamaters) {
    }

    private static String decode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return s;
        }
    }
}
