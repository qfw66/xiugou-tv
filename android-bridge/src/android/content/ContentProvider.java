package android.content;

import android.database.Cursor;
import android.net.Uri;

/**
 * 内容提供者基类。桌面端没有 manifest 驱动的组件启动，载荷里继承它的类（通常是初始化用的 provider）
 * 不会被系统创建；这里只提供可继承的基类与 attachInfo 生命周期。
 */
public abstract class ContentProvider {

    private Context context;

    public ContentProvider() {
    }

    public final Context getContext() {
        return context;
    }

    public final Context requireContext() {
        if (context == null) throw new IllegalStateException("Cannot find context from the provider.");
        return context;
    }

    public void attachInfo(Context context, android.content.pm.ProviderInfo info) {
        if (this.context == null) {
            this.context = context;
            onCreate();
        }
    }

    public abstract boolean onCreate();

    public abstract Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs,
                                 String sortOrder);

    public abstract String getType(Uri uri);

    public abstract Uri insert(Uri uri, ContentValues values);

    public abstract int delete(Uri uri, String selection, String[] selectionArgs);

    public abstract int update(Uri uri, ContentValues values, String selection, String[] selectionArgs);

    public void shutdown() {
    }
}
