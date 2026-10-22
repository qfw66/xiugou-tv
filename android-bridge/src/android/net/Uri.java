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

    private final String raw;
    private final java.net.URI parsed;

    private Uri(String raw, java.net.URI parsed) {
        this.raw = raw == null ? "" : raw;
        this.parsed = parsed;
    }

    public static Uri parse(String uriString) {
        if (uriString == null) return EMPTY;
        try {
            return new Uri(uriString, new java.net.URI(uriString));
        } catch (Exception e) {
            return new Uri(uriString, null);
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
        return parsed != null ? parsed.getScheme() : null;
    }

    public String getHost() {
        return parsed != null ? parsed.getHost() : null;
    }

    public int getPort() {
        return parsed != null ? parsed.getPort() : -1;
    }

    public String getAuthority() {
        return parsed != null ? parsed.getAuthority() : null;
    }

    public String getEncodedAuthority() {
        return getAuthority();
    }

    public String getPath() {
        return parsed != null ? parsed.getPath() : null;
    }

    public String getEncodedPath() {
        return parsed != null ? parsed.getRawPath() : null;
    }

    public String getQuery() {
        return parsed != null ? parsed.getQuery() : null;
    }

    public String getEncodedQuery() {
        return parsed != null ? parsed.getRawQuery() : null;
    }

    public String getFragment() {
        return parsed != null ? parsed.getFragment() : null;
    }

    public String getEncodedFragment() {
        return parsed != null ? parsed.getRawFragment() : null;
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
