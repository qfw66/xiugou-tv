package android.content;

/**
 * Minimal android.content.ContextWrapper stub。
 */
public class ContextWrapper extends Context {

    private Context base;

    public ContextWrapper() {
    }

    public ContextWrapper(Context base) {
        this.base = base;
    }

    public Context getBaseContext() {
        return base != null ? base : Context.get();
    }

    public Context getApplicationContext() {
        return getBaseContext().getApplicationContext();
    }
}
