package com.tencent.smtt.sdk;

/** X5 Cookie 与系统 WebView 共用宿主存储，避免同一站点形成两套登录态。 */
public final class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();

    private CookieManager() {
    }

    public static CookieManager getInstance() {
        return INSTANCE;
    }

    public String getCookie(String url) {
        return android.webkit.CookieManager.getInstance().getCookie(url);
    }

    public void setCookie(String url, String value) {
        android.webkit.CookieManager.getInstance().setCookie(url, value);
    }
}
