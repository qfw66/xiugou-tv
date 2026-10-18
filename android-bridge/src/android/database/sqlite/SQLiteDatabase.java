package android.database.sqlite;

import android.content.ContentValues;
import android.database.Cursor;

import java.io.File;

/**
 * Minimal android.database.sqlite.SQLiteDatabase stub for standard JVM environment。
 *
 * 加固载荷的初始化路径（InitOrigin.init → merge.ME）会打开本地配置库并读取少量配置行；
 * 桌面端不执行真实 SQLite 语义（无原生库），提供签名匹配的空实现：
 * 打开成功、无数据返回。若后续功能依赖配置内容，再考虑接入真实 SQLite 引擎。
 */
public class SQLiteDatabase extends SQLiteClosable {

    /** 与 Android 同名的工厂接口（桌面端仅需类型存在）。 */
    public interface CursorFactory {
    }

    private final String path;
    private boolean open = true;

    private SQLiteDatabase(String path) {
        this.path = path;
    }

    public static SQLiteDatabase openOrCreateDatabase(String path, CursorFactory factory) {
        return new SQLiteDatabase(path);
    }

    public static SQLiteDatabase openOrCreateDatabase(File file, CursorFactory factory) {
        return new SQLiteDatabase(file != null ? file.getPath() : "");
    }

    public static SQLiteDatabase openDatabase(String path, CursorFactory factory, int flags) {
        return new SQLiteDatabase(path);
    }

    public boolean isOpen() {
        return open;
    }

    public void close() {
        open = false;
    }

    public String getPath() {
        return path;
    }

    public void execSQL(String sql) {
    }

    public void execSQL(String sql, Object[] bindArgs) {
    }

    public Cursor rawQuery(String sql, String[] selectionArgs) {
        return new EmptyCursor();
    }

    public Cursor query(String table, String[] columns, String selection, String[] selectionArgs,
                        String groupBy, String having, String orderBy) {
        return new EmptyCursor();
    }

    public Cursor query(String table, String[] columns, String selection, String[] selectionArgs,
                        String groupBy, String having, String orderBy, String limit) {
        return new EmptyCursor();
    }

    public long insert(String table, String nullColumnHack, ContentValues values) {
        return -1;
    }

    public int update(String table, ContentValues values, String whereClause, String[] whereArgs) {
        return 0;
    }

    public int delete(String table, String whereClause, String[] whereArgs) {
        return 0;
    }

    public void beginTransaction() {
    }

    public void setTransactionSuccessful() {
    }

    public void endTransaction() {
    }

    /** 空游标：行数为 0，所有取值返回默认值。 */
    static class EmptyCursor implements Cursor {
        @Override
        public int getCount() {
            return 0;
        }

        @Override
        public int getPosition() {
            return 0;
        }

        @Override
        public boolean moveToPosition(int position) {
            return false;
        }

        @Override
        public boolean moveToFirst() {
            return false;
        }

        @Override
        public boolean moveToLast() {
            return false;
        }

        @Override
        public boolean moveToNext() {
            return false;
        }

        @Override
        public boolean moveToPrevious() {
            return false;
        }

        @Override
        public boolean isFirst() {
            return false;
        }

        @Override
        public boolean isLast() {
            return false;
        }

        @Override
        public boolean isAfterLast() {
            return false;
        }

        @Override
        public boolean isBeforeFirst() {
            return false;
        }

        @Override
        public boolean isClosed() {
            return false;
        }

        @Override
        public int getColumnIndex(String columnName) {
            return -1;
        }

        @Override
        public int getColumnIndexOrThrow(String columnName) {
            return -1;
        }

        @Override
        public String getColumnName(int columnIndex) {
            return "";
        }

        @Override
        public String[] getColumnNames() {
            return new String[0];
        }

        @Override
        public int getColumnCount() {
            return 0;
        }

        @Override
        public String getString(int columnIndex) {
            return null;
        }

        @Override
        public short getShort(int columnIndex) {
            return 0;
        }

        @Override
        public int getInt(int columnIndex) {
            return 0;
        }

        @Override
        public long getLong(int columnIndex) {
            return 0;
        }

        @Override
        public float getFloat(int columnIndex) {
            return 0;
        }

        @Override
        public double getDouble(int columnIndex) {
            return 0;
        }

        @Override
        public byte[] getBlob(int columnIndex) {
            return null;
        }

        @Override
        public boolean isNull(int columnIndex) {
            return true;
        }

        @Override
        public void close() {
        }
    }
}
