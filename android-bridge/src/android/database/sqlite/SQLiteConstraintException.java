package android.database.sqlite;

/**
 * 违反约束（唯一键等）时抛出的异常。
 */
public class SQLiteConstraintException extends SQLiteException {

    public SQLiteConstraintException() {
    }

    public SQLiteConstraintException(String error) {
        super(error);
    }
}
