package android.database.sqlite;

/**
 * SQLite 操作异常。
 */
public class SQLiteException extends android.database.SQLException {

    public SQLiteException() {
    }

    public SQLiteException(String error) {
        super(error);
    }

    public SQLiteException(String error, Throwable cause) {
        super(error, cause);
    }
}
