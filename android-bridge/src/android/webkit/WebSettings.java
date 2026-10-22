package android.webkit;

import android.os.Build;

import java.io.File;

/**
 * android.webkit.WebSettings 的最小桌面实现。
 *
 * <p>存在意义：ftyguard/wexguard 载荷的 {@code InitOrigin} 会把 UA 换成
 * 「WebView 的默认 UA」（{@code new WebView(ctx).getSettings().getUserAgentString()}）。
 * 桌面端没有真实 WebView，这里提供一个**形态可信的 Android WebView UA**，
 * 让载荷拿到的指纹与手机端一致（而不是抛 {@code NoClassDefFoundError} 后保留字符串表里的 UA）。
 *
 * <p>可用 {@code -Dxiugou.webview.ua=<UA>} 覆盖默认值；设为空串则退回内置默认。
 */
public class WebSettings {

    public static final int MIXED_CONTENT_ALWAYS_ALLOW = 0;
    public static final int MIXED_CONTENT_NEVER_ALLOW = 1;
    public static final int MIXED_CONTENT_COMPATIBILITY_MODE = 2;

    public static final int LOAD_DEFAULT = -1;
    public static final int LOAD_CACHE_ELSE_NETWORK = 1;
    public static final int LOAD_NO_CACHE = 2;
    public static final int LOAD_CACHE_ONLY = 3;

    private static final String DEFAULT_UA = buildDefaultUa();

    private String userAgentString = defaultUa();
    private int cacheMode = LOAD_DEFAULT;
    private boolean javaScriptEnabled;
    private boolean domStorageEnabled;
    private boolean databaseEnabled;
    private boolean blockNetworkImage;
    private int mixedContentMode = MIXED_CONTENT_NEVER_ALLOW;

    /** 手机 WebView 的典型 UA 形态：Linux; Android <ver>; <model> Build/<id>; wv。 */
    private static String buildDefaultUa() {
        String override = System.getProperty("xiugou.webview.ua", "");
        if (!override.isEmpty()) return override;
        return "Mozilla/5.0 (Linux; Android " + Build.VERSION.RELEASE + "; " + Build.MODEL
                + " Build/" + Build.ID + "; wv) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Version/4.0 Chrome/90.0.4430.91 Mobile Safari/537.36";
    }

    private static String defaultUa() {
        return DEFAULT_UA;
    }

    public String getUserAgentString() {
        return userAgentString;
    }

    public void setUserAgentString(String ua) {
        if (ua != null && !ua.isEmpty()) {
            this.userAgentString = ua;
        }
    }

    public void setJavaScriptEnabled(boolean flag) {
        this.javaScriptEnabled = flag;
    }

    public void setDomStorageEnabled(boolean flag) {
        this.domStorageEnabled = flag;
    }

    public void setDatabaseEnabled(boolean flag) {
        this.databaseEnabled = flag;
    }

    public void setMixedContentMode(int mode) {
        this.mixedContentMode = mode;
    }

    public void setBlockNetworkImage(boolean flag) {
        this.blockNetworkImage = flag;
    }

    public void setCacheMode(int mode) {
        this.cacheMode = mode;
    }

    public void setSupportMultipleWindows(boolean support) {
    }

    public void setJavaScriptCanOpenWindowsAutomatically(boolean flag) {
    }

    public void setLoadsImagesAutomatically(boolean flag) {
    }

    public void setAllowFileAccess(boolean allow) {
    }

    public void setAllowContentAccess(boolean allow) {
    }

    public void setMediaPlaybackRequiresUserGesture(boolean require) {
    }

    public void setAppCacheEnabled(boolean flag) {
    }

    public void setAppCachePath(String path) {
    }

    public void setDefaultTextEncodingName(String encoding) {
    }

    public void setUseWideViewPort(boolean use) {
    }

    public void setLoadWithOverviewMode(boolean overview) {
    }

    public void setBuiltInZoomControls(boolean enabled) {
    }

    public void setDisplayZoomControls(boolean enabled) {
    }

    public boolean getJavaScriptEnabled() {
        return javaScriptEnabled;
    }

    public boolean getDomStorageEnabled() {
        return domStorageEnabled;
    }

    public boolean getDatabaseEnabled() {
        return databaseEnabled;
    }

    public int getMixedContentMode() {
        return mixedContentMode;
    }

    public int getCacheMode() {
        return cacheMode;
    }

    /** Android 10+ 的 {@code setForceDark}；部分壳会调用。 */
    public void setForceDark(int mode) {
    }

    public void setForceDarkAllowed(boolean allow) {
    }

    public void setTextZoom(int textZoom) {
    }

    public int getTextZoom() {
        return 100;
    }

    public void setGeolocationEnabled(boolean flag) {
    }

    public void setSaveFormData(boolean save) {
    }

    public void setSavePassword(boolean save) {
    }

    /** 仅供调试：导出当前值。 */
    public File getAppCachePath() {
        return null;
    }
}
