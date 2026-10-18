package android.content;

public class ComponentName {

    private final String pkg;
    private final String cls;

    public ComponentName(String pkg, String cls) {
        this.pkg = pkg;
        this.cls = cls;
    }

    public ComponentName(Context context, String cls) {
        this(context.getPackageName(), cls);
    }

    public ComponentName(Context context, Class<?> cls) {
        this(context.getPackageName(), cls.getName());
    }

    public String getPackageName() {
        return pkg;
    }

    public String getClassName() {
        return cls;
    }

    public String flattenToString() {
        return pkg + "/" + cls;
    }

    @Override
    public String toString() {
        return "ComponentInfo{" + pkg + "/" + cls + "}";
    }
}
