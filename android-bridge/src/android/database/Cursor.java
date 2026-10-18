package android.database;

/**
 * Minimal android.database.Cursor stub for standard JVM environment.
 * 方法子集按 Android 标准 API 定义，供加固载荷（merge.ME 等）的配置读取路径使用。
 */
public interface Cursor {

    int getCount();

    int getPosition();

    boolean moveToPosition(int position);

    boolean moveToFirst();

    boolean moveToLast();

    boolean moveToNext();

    boolean moveToPrevious();

    boolean isFirst();

    boolean isLast();

    boolean isAfterLast();

    boolean isBeforeFirst();

    boolean isClosed();

    int getColumnIndex(String columnName);

    int getColumnIndexOrThrow(String columnName);

    String getColumnName(int columnIndex);

    String[] getColumnNames();

    int getColumnCount();

    String getString(int columnIndex);

    short getShort(int columnIndex);

    int getInt(int columnIndex);

    long getLong(int columnIndex);

    float getFloat(int columnIndex);

    double getDouble(int columnIndex);

    byte[] getBlob(int columnIndex);

    boolean isNull(int columnIndex);

    void close();
}
