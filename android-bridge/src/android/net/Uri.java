package android.net;

import java.io.File;
import java.io.UnsupportedEncodingException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * android.net.Uri 的桌面实现。
 *
 * <p>载荷大量使用（{@code parse} 8 处、{@code getLastPathSegment} 5 处、{@code buildUpon}+
 * {@code Builder} 若干）。这里不追求 RFC 完全一致，只保证两类语义：
 * <ul>
 *   <li><b>永不抛异常</b>：Android 的 {@code Uri.parse} 对畸形字符串是宽松的，返回原串仍可用；
 *       早期实现失败时返回 {@code http://localhost}，会把站点 URL 悄悄改错，这里改为保留原串。</li>
 *   <li><b>取不到就返回 null/空</b>：{@code getLastPathSegment} 等按 Android 约定返回 null。</li>
 * </ul>
 */
public class Uri {

    public static final Uri EMPTY = new Uri("", null);

    /** RFC 3986 附录 B 的通用拆分正则，任何字符串都能匹配。 */
    private static final java.util.regex.Pattern RFC3986 = java.util.regex.Pattern.compile(
            "^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\\?([^#]*))?(#(.*))?");

    private final String raw;
    private final java.net.URI parsed;
    /** {@code java.net.URI} 拒绝的串（如查询里含 {@code |}）按 RFC 3986 宽松拆出的各段。 */
    private final Lenient lenient;

    private Uri(String raw, java.net.URI parsed) {
        this.raw = raw == null ? "" : raw;
        this.parsed = parsed;
        this.lenient = parsed == null && !this.raw.isEmpty() ? Lenient.of(this.raw) : null;
    }

    /**
     * 与 Android 一样宽松：{@code java.net.URI} 拒绝的串也能取到 scheme/host/path/query。
     *
     * <p>issue #11：夸克扫码地址查询里含 {@code |}，严格解析失败时 host 为 null，载荷的
     * 「本机地址换局域网 IP」逻辑把它当成本机地址，二维码内容被改成 {@code //192.168.x.x}。
     */
    public static Uri parse(String uriString) {
        if (uriString == null) return EMPTY;
        try {
            return new Uri(uriString, new java.net.URI(uriString));
        } catch (Exception e) {
            return new Uri(uriString, null);
        }
    }

    private static final class Lenient {
        final String scheme;
        final String authority;
        final String userInfo;
        final String host;
        final int port;
        final String path;
        final String query;
        final String fragment;

        private Lenient(String scheme, String authority, String path, String query, String fragment) {
            this.scheme = scheme;
            this.authority = authority;
            this.path = path;
            this.query = query;
            this.fragment = fragment;
            String ui = null;
            String h = null;
            int p = -1;
            if (authority != null) {
                String hostPort = authority;
                int at = hostPort.lastIndexOf('@');
                if (at >= 0) {
                    ui = hostPort.substring(0, at);
                    hostPort = hostPort.substring(at + 1);
                }
                String portText = null;
                if (hostPort.startsWith("[")) {
                    int close = hostPort.indexOf(']');
                    if (close > 0) {
                        h = hostPort.substring(0, close + 1);
                        if (close + 1 < hostPort.length() && hostPort.charAt(close + 1) == ':') {
                            portText = hostPort.substring(close + 2);
                        }
                    } else {
                        h = hostPort;
                    }
                } else {
                    int colon = hostPort.lastIndexOf(':');
                    if (colon >= 0) {
                        h = hostPort.substring(0, colon);
                        portText = hostPort.substring(colon + 1);
                    } else {
                        h = hostPort;
                    }
                }
                if (portText != null && !portText.isEmpty()) {
                    try {
                        p = Integer.parseInt(portText);
                    } catch (NumberFormatException ignored) {
                        p = -1;
                    }
                }
                if (h != null && h.isEmpty()) h = null;
            }
            this.userInfo = ui;
            this.host = h;
            this.port = p;
        }

        static Lenient of(String raw) {
            java.util.regex.Matcher m = RFC3986.matcher(raw);
            if (!m.find()) return null;
            return new Lenient(m.group(2), m.group(4), m.group(5), m.group(7), m.group(9));
        }
    }

    public static Uri fromFile(File file) {
        return parse(file == null ? "" : file.toURI().toString());
    }

    public static Uri fromParts(String scheme, String ssp, String fragment) {
        return parse((scheme == null ? "" : scheme) + ":" + (ssp == null ? "" : ssp)
                + (fragment == null ? "" : "#" + fragment));
    }

    public static String encode(String s) {
        return encode(s, null);
    }

    public static String encode(String s, String allow) {
        if (s == null) return null;
        try {
            String out = URLEncoder.encode(s, "UTF-8").replace("+", "%20");
            return out;
        } catch (UnsupportedEncodingException e) {
            return s;
        }
    }

    public static String decode(String s) {
        if (s == null) return null;
        try {
            return URLDecoder.decode(s, "UTF-8");
        } catch (Exception e) {
            return s;
        }
    }

    public Builder buildUpon() {
        return new Builder().scheme(getScheme()).encodedAuthority(getEncodedAuthority())
                .encodedPath(getEncodedPath()).encodedQuery(getEncodedQuery())
                .encodedFragment(getEncodedFragment());
    }

    public String getScheme() {
        if (parsed != null) return parsed.getScheme();
        return lenient != null ? lenient.scheme : null;
    }

    public String getHost() {
        if (parsed != null) return parsed.getHost();
        return lenient != null ? lenient.host : null;
    }

    public int getPort() {
        if (parsed != null) return parsed.getPort();
        return lenient != null ? lenient.port : -1;
    }

    public String getAuthority() {
        if (parsed != null) return parsed.getAuthority();
        return lenient != null ? percentDecode(lenient.authority) : null;
    }

    public String getEncodedAuthority() {
        if (parsed != null) return parsed.getAuthority();
        return lenient != null ? lenient.authority : null;
    }

    public String getUserInfo() {
        if (parsed != null) return parsed.getUserInfo();
        return lenient != null ? percentDecode(lenient.userInfo) : null;
    }

    public String getEncodedUserInfo() {
        if (parsed != null) return parsed.getRawUserInfo();
        return lenient != null ? lenient.userInfo : null;
    }

    public String getPath() {
        if (parsed != null) return parsed.getPath();
        return lenient != null ? percentDecode(lenient.path) : null;
    }

    public String getEncodedPath() {
        if (parsed != null) return parsed.getRawPath();
        return lenient != null ? lenient.path : null;
    }

    public String getQuery() {
        if (parsed != null) return parsed.getQuery();
        return lenient != null ? percentDecode(lenient.query) : null;
    }

    public String getEncodedQuery() {
        if (parsed != null) return parsed.getRawQuery();
        return lenient != null ? lenient.query : null;
    }

    public String getFragment() {
        if (parsed != null) return parsed.getFragment();
        return lenient != null ? percentDecode(lenient.fragment) : null;
    }

    public String getEncodedFragment() {
        if (parsed != null) return parsed.getRawFragment();
        return lenient != null ? lenient.fragment : null;
    }

    /** 只解 {@code %XX}，不把 {@code +} 当空格（URI 语义）；解不了时原样返回。 */
    private static String percentDecode(String s) {
        if (s == null || s.indexOf('%') < 0) return s;
        try {
            return URLDecoder.decode(s.replace("+", "%2B"), "UTF-8");
        } catch (Exception e) {
            return s;
        }
    }

    public List<String> getPathSegments() {
        String path = getPath();
        if (path == null || path.isEmpty()) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        for (String part : path.split("/")) {
            if (!part.isEmpty()) out.add(part);
        }
        return out;
    }

    /** Android 约定：路径最后一段；没有则返回 null（不是空串）。 */
    public String getLastPathSegment() {
        List<String> segs = getPathSegments();
        return segs.isEmpty() ? null : segs.get(segs.size() - 1);
    }

    public String getQueryParameter(String key) {
        Map<String, String> all = queryMap();
        return all.get(key);
    }

    public List<String> getQueryParameters(String key) {
        String v = getQueryParameter(key);
        return v == null ? Collections.emptyList() : Collections.singletonList(v);
    }

    public java.util.Set<String> getQueryParameterNames() {
        return queryMap().keySet();
    }

    private Map<String, String> queryMap() {
        String q = getEncodedQuery();
        if (q == null || q.isEmpty()) return Collections.emptyMap();
        Map<String, String> out = new LinkedHashMap<>();
        for (String pair : q.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String k = eq < 0 ? pair : pair.substring(0, eq);
            String v = eq < 0 ? "" : pair.substring(eq + 1);
            out.put(decode(k), decode(v));
        }
        return out;
    }

    @Override
    public String toString() {
        return raw;
    }

    @Override
    public boolean equals(Object o) {
        return o instanceof Uri && raw.equals(((Uri) o).raw);
    }

    @Override
    public int hashCode() {
        return raw.hashCode();
    }

    /** android.net.Uri.Builder。 */
    public static final class Builder {
        private String scheme = "";
        private String authority = "";
        private String path = "";
        private String query = "";
        private String fragment = "";

        public Builder() {
        }

        public Builder scheme(String scheme) {
            this.scheme = scheme == null ? "" : scheme;
            return this;
        }

        public Builder authority(String authority) {
            this.authority = authority == null ? "" : authority;
            return this;
        }

        public Builder encodedAuthority(String authority) {
            return authority(authority);
        }

        public Builder path(String path) {
            this.path = path == null ? "" : path;
            return this;
        }

        public Builder encodedPath(String path) {
            return path(path);
        }

        public Builder appendPath(String newSegment) {
            if (newSegment == null) return this;
            if (path == null || path.isEmpty()) {
                path = "/" + newSegment;
            } else if (path.endsWith("/")) {
                path = path + newSegment;
            } else {
                path = path + "/" + newSegment;
            }
            return this;
        }

        public Builder query(String query) {
            this.query = query == null ? "" : query;
            return this;
        }

        public Builder encodedQuery(String query) {
            return query(query);
        }

        public Builder appendQueryParameter(String key, String value) {
            if (key == null) return this;
            String pair = encode(key) + "=" + encode(value == null ? "" : value);
            query = (query == null || query.isEmpty()) ? pair : query + "&" + pair;
            return this;
        }

        public Builder fragment(String fragment) {
            this.fragment = fragment == null ? "" : fragment;
            return this;
        }

        public Builder encodedFragment(String fragment) {
            return fragment(fragment);
        }

        public Builder clearQuery() {
            query = "";
            return this;
        }

        public Uri build() {
            StringBuilder sb = new StringBuilder();
            if (!scheme.isEmpty()) sb.append(scheme).append(':');
            if (!authority.isEmpty() || !path.isEmpty() || !query.isEmpty()) sb.append("//");
            if (!authority.isEmpty()) sb.append(authority);
            if (!path.isEmpty()) {
                if (!path.startsWith("/") && sb.length() > 0) sb.append('/');
                sb.append(path);
            }
            if (!query.isEmpty()) sb.append('?').append(query);
            if (!fragment.isEmpty()) sb.append('#').append(fragment);
            return Uri.parse(sb.toString());
        }

        @Override
        public String toString() {
            return build().toString();
        }
    }
}
