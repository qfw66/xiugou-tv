package android.database.sqlite;

/**
 * Minimal android.database.sqlite.SQLiteClosable stub for standard JVM environment.
 */
public abstract class SQLiteClosable {

    private int referenceCount = 1;

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
