package android.util;

/**
 * Minimal Android Base64 stub delegating to java.util.Base64.
 */
public class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;

    public static byte[] decode(String str, int flags) {
        if (str == null) return new byte[0];
        try {
            if ((flags & URL_SAFE) != 0) {
                return java.util.Base64.getUrlDecoder().decode(str.trim());
            }
            return java.util.Base64.getDecoder().decode(str.trim());
        } catch (Exception e) {
            try {
                return java.util.Base64.getUrlDecoder().decode(str.trim());
            } catch (Exception ex) {
                return new byte[0];
            }
        }
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(new String(input, java.nio.charset.StandardCharsets.UTF_8), flags);
    }

    public static String encodeToString(byte[] input, int flags) {
        if (input == null) return "";
        if ((flags & URL_SAFE) != 0) {
            return java.util.Base64.getUrlEncoder().encodeToString(input);
        }
        return java.util.Base64.getEncoder().encodeToString(input);
    }

    public static byte[] encode(byte[] input, int flags) {
        if (input == null) return new byte[0];
        if ((flags & URL_SAFE) != 0) {
            return java.util.Base64.getUrlEncoder().encode(input);
        }
        return java.util.Base64.getEncoder().encode(input);
    }
}
