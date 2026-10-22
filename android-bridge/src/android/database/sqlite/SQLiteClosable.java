package android.database.sqlite;

/**
 * Minimal android.database.sqlite.SQLiteClosable stub for standard JVM environment.
 */
public abstract class SQLiteClosable {

    private int referenceCount = 1;

    /**
     * Android 在 {@code SQLiteClosable} 上就声明了 {@code close()}（子类 {@link SQLiteDatabase}
     * 覆盖它）。载荷（merge.g8 的 SQLite 分支）按 {@code SQLiteClosable} 静态类型调用，
     * 缺这个方法会抛 {@code NoSuchMethodError} 并打断 {@code InitOrigin.init}。
     */
    public void close() {
        onAllReferencesReleased();
    }

    protected void onAllReferencesReleased() {
    }

    public void acquireReference() {
        referenceCount++;
    }

    public void releaseReference() {
        if (--referenceCount == 0) {
            onAllReferencesReleased();
        }
    }

    public void releaseReferenceFromContainer() {
        releaseReference();
    }
}
