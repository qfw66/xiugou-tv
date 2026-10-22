package android.webkit;

import android.graphics.Bitmap;

/**
 * android.webkit.WebViewClient 的最小实现：所有回调都是「不拦、不处理」。
 *
 * <p>载荷只做 {@code setWebViewClient(new WebViewClient(){...})} 或传 null；
 * 桌面端不加载页面，因此这些回调不会被本工程的 {@link WebView} 主动触发。
 */
public class WebViewClient {

    public boolean shouldOverrideUrlLoading(WebView view, String url) {
        return false;
    }

    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        return false;
    }

    public WebResourceResponse shouldInterceptRequest(WebView view, String url) {
        return null;
    }

    public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
        return null;
    }

    public void onPageStarted(WebView view, String url, Bitmap favicon) {
    }

    public void onPageFinished(WebView view, String url) {
    }

    public void onLoadResource(WebView view, String url) {
    }

    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
    }

    public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
    }
}
