package android.text;

/**
 * Minimal Android TextUtils stub.
 */
public class TextUtils {
    public static boolean isEmpty(CharSequence str) {
        if (str == null) return true;
        // 刻意不调用 CharSequence.length()：加固载荷在 -noverify 下会把类型错位的对象传进来，
        // 接口分发被 JIT 内联后会直接崩（实测 EXCEPTION_ACCESS_VIOLATION @ isEmpty+5，两次）。
        // Object.toString() 是虚方法分发，对任何对象都安全。
        return str.toString().length() == 0;
    }

    public static boolean equals(CharSequence a, CharSequence b) {
        if (a == b) return true;
        if (a == null || b == null) return false;
        // 同上：统一走 toString()，避免 CharSequence 接口分发
        return a.toString().equals(b.toString());
    }

    /**
     * Android 标准方法：join(CharSequence, Iterable)。
     * 手机端 spider（如 XBiu.homeContent → WH()）直接调用；缺失会导致
     * NoSuchMethodError: android.text.TextUtils.join(CharSequence, Iterable)。
     */
    public static String join(CharSequence delimiter, Iterable<?> tokens) {
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        for (Object token : tokens) {
            if (first) {
                first = false;
            } else {
                sb.append(delimiter);
            }
            sb.append(token);
        }
        return sb.toString();
    }

    /** Android 标准方法：join(CharSequence, Object[])。 */
    public static String join(CharSequence delimiter, Object[] tokens) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < tokens.length; i++) {
            if (i > 0) sb.append(delimiter);
            sb.append(tokens[i]);
        }
        return sb.toString();
    }
}
