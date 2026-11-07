package android.content;

import android.net.Uri;

/** 只为载荷类的静态初始化能跑完；桌面没有 content:// 提供者，match 一律返回 NO_MATCH。 */
public class UriMatcher {
    public static final int NO_MATCH = -1;
    private final int code;

    public UriMatcher(int code) {
        this.code = code;
    }

    public void addURI(String authority, String path, int code) {
    }

    public int match(Uri uri) {
        return code;
    }
}
