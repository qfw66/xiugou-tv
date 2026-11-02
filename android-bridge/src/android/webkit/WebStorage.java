package android.webkit;

/**
 * android.webkit.WebStorage 的桌面空实现：桌面 WebView 不执行页面脚本，没有 localStorage / IndexedDB 可清。
 * 载荷（如王二小弹幕网页）在初始化网页前调用 {@code getInstance().deleteAllData()}，缺类会让整段初始化失败。
 */
public class WebStorage {

    private static final WebStorage INSTANCE = new WebStorage();

    protected WebStorage() {
    }

    public static WebStorage getInstance() {
        return INSTANCE;
    }

    public void deleteAllData() {
    }

    public void deleteOrigin(String origin) {
    }
}
