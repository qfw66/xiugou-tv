package android.content;

import android.net.Uri;

public class ContentUris {

    public static long parseId(Uri uri) {
        String last = uri == null ? null : uri.getLastPathSegment();
        return last == null ? -1 : Long.parseLong(last);
    }

    public static Uri withAppendedId(Uri uri, long id) {
        String base = uri.toString();
        return Uri.parse(base.endsWith("/") ? base + id : base + "/" + id);
    }
}
