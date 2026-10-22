package android.webkit;

import android.content.Context;
import android.view.View;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * android.webkit.WebView 的桌面空实现。
 *
 * <p>只承载「载荷会读写的那几个成员」：UA 换装（{@link WebSettings#getUserAgentString()}）、
 * 客户端注册、loadUrl 记录。桌面端没有渲染引擎，{@link #loadUrl(String)} 不会真的发请求——
 * 让它保持惰性比「假装加载」更安全：一旦回调 {@code shouldInterceptRequest}，载荷会以为页面
 * 已加载并进入依赖 JS 的分支。
 */
public class WebView extends View {

    private WebSettings settings;
    private WebViewClient webViewClient;
    private WebChromeClient webChromeClient;
    private String url;
    private final List<String> history = Collections.synchronizedList(new ArrayList<String>());

    public WebView(Context context) {
        super(context);
    }

    public WebSettings getSettings() {
        if (settings == null) settings = new WebSettings();
        return settings;
    }

    public void setWebViewClient(WebViewClient client) {
        this.webViewClient = client;
    }

    public WebViewClient getWebViewClient() {
        return webViewClient;
    }

    public void setWebChromeClient(WebChromeClient client) {
        this.webChromeClient = client;
    }

    public WebChromeClient getWebChromeClient() {
        return webChromeClient;
    }

    public void loadUrl(String url) {
        loadUrl(url, null);
    }

    public void loadUrl(String url, Map<String, String> headers) {
        this.url = url;
        if (url != null) history.add(url);
    }

    public void loadData(String data, String mimeType, String encoding) {
    }

    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType,
                                    String encoding, String historyUrl) {
    }

    public String getUrl() {
        return url;
    }

    public String getOriginalUrl() {
        return url;
    }

    public void reload() {
    }

    public void stopLoading() {
    }

    public boolean canGoBack() {
        return false;
    }

    public void goBack() {
    }

    public void clearHistory() {
        history.clear();
    }

    public void clearCache(boolean includeDiskFiles) {
    }

    public void clearFormData() {
    }

    public void addJavascriptInterface(Object object, String name) {
    }

    public void removeJavascriptInterface(String name) {
    }

    public void evaluateJavascript(String script, ValueCallback<String> callback) {
        if (callback != null) callback.onReceiveValue(null);
    }

    public void postUrl(String url, byte[] postData) {
        loadUrl(url);
    }

    public void setInitialScale(int scaleInPercent) {
    }

    public void setBackgroundColor(int color) {
        super.setBackgroundColor(color);
    }

    public void destroy() {
        webViewClient = null;
        webChromeClient = null;
        settings = null;
    }

    /** {@code WebView} 在部分壳里通过 {@code LayoutParams} 设置尺寸；保持继承自 View 的语义即可。 */
    @Override
    public String toString() {
        return "WebView(" + url + ")";
    }
}
