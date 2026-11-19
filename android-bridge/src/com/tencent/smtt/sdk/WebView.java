package com.tencent.smtt.sdk;

import android.content.Context;
import android.widget.FrameLayout;

/**
 * X5 的桌面 ABI 适配器；复用惰性 WebView，不执行页面、脚本或加载完成回调。
 * X5 的 Android 类型继承 FrameLayout，不能用系统 WebView 替代这一继承关系。
 */
public class WebView extends FrameLayout {
    private final android.webkit.WebView delegate;
    private WebSettings settings = new WebSettings();
    private WebViewClient client;
    private WebChromeClient chromeClient;

    public WebView(Context context) {
        super(context);
        delegate = new android.webkit.WebView(context);
    }

    public WebSettings getSettings() {
        if (settings == null) settings = new WebSettings();
        return settings;
    }

    public void setWebViewClient(WebViewClient client) {
        this.client = client;
    }

    public WebViewClient getWebViewClient() {
        return client;
    }

    public void setWebChromeClient(WebChromeClient client) {
        chromeClient = client;
    }

    public WebChromeClient getWebChromeClient() {
        return chromeClient;
    }

    public void loadUrl(String url) {
        delegate.loadUrl(url);
    }

    public String getUrl() {
        return delegate.getUrl();
    }

    public void stopLoading() {
        delegate.stopLoading();
    }

    public void addJavascriptInterface(Object object, String name) {
        delegate.addJavascriptInterface(object, name);
    }

    public void evaluateJavascript(String script, ValueCallback<String> callback) {
        delegate.evaluateJavascript(script, callback == null ? null : callback::onReceiveValue);
    }

    public void destroy() {
        delegate.destroy();
        client = null;
        chromeClient = null;
        settings = null;
    }
}
