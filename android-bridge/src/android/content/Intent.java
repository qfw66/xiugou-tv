package android.content;

import android.net.Uri;

import java.util.HashMap;
import java.util.Map;

/**
 * android.content.Intent 的桌面实现：保存动作、数据地址、类型、标志与附加值。
 *
 * <p>桌面端没有 Activity 栈，{@link Context#startActivity} 只处理带数据地址的跳转（打开网页 / 唤起 App），
 * 交给宿主决定如何呈现。
 */
public class Intent {

    public static final String ACTION_VIEW = "android.intent.action.VIEW";
    public static final String ACTION_SEND = "android.intent.action.SEND";
    public static final String ACTION_MAIN = "android.intent.action.MAIN";
    public static final String EXTRA_TEXT = "android.intent.extra.TEXT";
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;
    public static final int FLAG_ACTIVITY_CLEAR_TOP = 0x04000000;
    public static final int FLAG_GRANT_READ_URI_PERMISSION = 0x00000001;

    private String action;
    private ComponentName component;
    private Uri data;
    private String type;
    private String packageName;
    private int flags;
    private final Map<String, Object> extras = new HashMap<>();

    public Intent() {
    }

    public Intent(String action) {
        this.action = action;
    }

    public Intent(String action, Uri uri) {
        this.action = action;
        this.data = uri;
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

    public Intent setClassName(Context packageContext, String className) {
        this.component = new ComponentName(packageContext, className);
        return this;
    }

    public Intent setPackage(String packageName) {
        this.packageName = packageName;
        return this;
    }

    public String getPackage() {
        return packageName;
    }

    public Uri getData() {
        return data;
    }

    public String getDataString() {
        return data == null ? null : data.toString();
    }

    public Intent setData(Uri data) {
        this.data = data;
        return this;
    }

    public String getType() {
        return type;
    }

    public Intent setType(String type) {
        this.type = type;
        return this;
    }

    public Intent setDataAndType(Uri data, String type) {
        this.data = data;
        this.type = type;
        return this;
    }

    public int getFlags() {
        return flags;
    }

    public Intent setFlags(int flags) {
        this.flags = flags;
        return this;
    }

    public Intent addFlags(int flags) {
        this.flags |= flags;
        return this;
    }

    public Intent addCategory(String category) {
        return this;
    }

    public boolean hasExtra(String name) {
        return extras.containsKey(name);
    }

    public String getStringExtra(String name) {
        Object v = extras.get(name);
        return v == null ? null : v.toString();
    }

    public boolean getBooleanExtra(String name, boolean defaultValue) {
        Object v = extras.get(name);
        return v instanceof Boolean ? (Boolean) v : defaultValue;
    }

    public int getIntExtra(String name, int defaultValue) {
        Object v = extras.get(name);
        return v instanceof Integer ? (Integer) v : defaultValue;
    }

    public long getLongExtra(String name, long defaultValue) {
        Object v = extras.get(name);
        return v instanceof Long ? (Long) v : defaultValue;
    }

    public Intent putExtra(String name, String value) {
        extras.put(name, value);
        return this;
    }

    public Intent putExtra(String name, CharSequence value) {
        extras.put(name, value);
        return this;
    }

    public Intent putExtra(String name, boolean value) {
        extras.put(name, value);
        return this;
    }

    public Intent putExtra(String name, int value) {
        extras.put(name, value);
        return this;
    }

    public Intent putExtra(String name, long value) {
        extras.put(name, value);
        return this;
    }

    public static Intent createChooser(Intent target, CharSequence title) {
        return target;
    }
}
