package android.database;

/**
 * SQL 执行异常基类。
 */
public class SQLException extends RuntimeException {

    public SQLException() {
    }

    public SQLException(String error) {
        super(error);
    }

    public SQLException(String error, Throwable cause) {
        super(error, cause);
    }
}
