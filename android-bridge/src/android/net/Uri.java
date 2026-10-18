package android.net;

/**
 * Minimal Android Uri stub.
 */
public class Uri {
    private final java.net.URI uri;

    private Uri(java.net.URI uri) {
        this.uri = uri;
    }

    public static Uri parse(String uriString) {
        try {
            return new Uri(java.net.URI.create(uriString));
        } catch (Exception e) {
            return new Uri(java.net.URI.create("http://localhost"));
        }
    }

    public String getHost() {
        return uri != null ? uri.getHost() : "";
    }

    public String getScheme() {
        return uri != null ? uri.getScheme() : "";
    }

    public String getPath() {
        return uri != null ? uri.getPath() : "";
    }

    public String getQuery() {
        return uri != null ? uri.getQuery() : "";
    }

    @Override
    public String toString() {
        return uri != null ? uri.toString() : "";
    }
}
