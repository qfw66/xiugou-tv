package android.content;

/**
 * Minimal android.content.Intent stub。
 */
public class Intent {

    private String action;
    private ComponentName component;

    public Intent() {
    }

    public Intent(String action) {
        this.action = action;
    }

    public Intent(Context packageContext, Class<?> cls) {
        this.component = new ComponentName(packageContext, cls);
    }

    public String getAction() {
        return action;
    }

    public Intent setAction(String action) {
        this.action = action;
        return this;
    }

    public ComponentName getComponent() {
        return component;
    }

    public Intent setComponent(ComponentName component) {
        this.component = component;
        return this;
    }

    public Intent setClassName(String packageName, String className) {
        this.component = new ComponentName(packageName, className);
        return this;
    }

    public String getStringExtra(String name) {
        return null;
    }

    public Intent putExtra(String name, String value) {
        return this;
    }
}
