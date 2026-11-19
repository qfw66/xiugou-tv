package com.tencent.smtt.sdk;

/** 无浏览器内核时不主动触发页面回调。 */
public class WebChromeClient {
    public void onProgressChanged(WebView view, int progress) {
    }

    public void onReceivedTitle(WebView view, String title) {
    }
}
