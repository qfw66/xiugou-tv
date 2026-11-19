package com.github.catvod.crawler;

import android.content.Context;

import com.github.catvod.net.OkHttp;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import okhttp3.Dns;
import okhttp3.OkHttpClient;

/**
 * Standard Spider interface aligned with TVBox CatVod specification.
 */
public abstract class Spider {
    public String siteKey = "";
    public final com.github.catvod.net.Net net = new com.github.catvod.net.Net();
    private final java.util.Set<com.github.catvod.utils.Dialog> hostDialogs = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private final Object hostLifecycle = new Object();
    private volatile java.util.function.Function<Map<String, String>, String> hostProxy;
    private volatile boolean hostClosed;

    /** Installed only by the loader, bound to this registered instance. */
    public final void bindHostProxy(java.util.function.Function<Map<String, String>, String> proxy) {
        synchronized (hostLifecycle) {
            if (hostClosed) throw new IllegalStateException("Spider has been released");
            hostProxy = proxy;
        }
    }

    public String proxyUrl(Map<String, String> params) { return proxyUrl(params, true); }

    /** Desktop proxy URLs remain loopback-only, including local=false. */
    public String proxyUrl(Map<String, String> params, boolean local) {
        var proxy = hostProxy;
        if (hostClosed || proxy == null) throw new IllegalStateException("Spider proxy is not registered");
        return proxy.apply(params);
    }

    public org.json.JSONObject dialog(org.json.JSONObject spec) { return dialog(spec, null); }

    public org.json.JSONObject dialog(org.json.JSONObject spec, com.github.catvod.utils.Dialog.Callback callback) {
        var dialog = new com.github.catvod.utils.Dialog();
        synchronized (hostLifecycle) {
            if (hostClosed) return null;
            hostDialogs.add(dialog);
        }
        try { return dialog.show(spec, callback); }
        finally { hostDialogs.remove(dialog); dialog.close(); }
    }

    /** Called independently of destroy overrides, including failed or cancelled initialization. */
    public final void closeHostResources() {
        synchronized (hostLifecycle) { hostClosed = true; hostProxy = null; }
        hostDialogs.forEach(com.github.catvod.utils.Dialog::close);
        hostDialogs.clear();
        net.close();
    }

    /** 对齐手机端 catvod Spider：spider jar 常用 Spider.safeDns() 构造自定义 OkHttpClient。 */
    public static Dns safeDns() {
        return OkHttp.dns();
    }

    /** 对齐手机端 catvod Spider：共享 OkHttpClient。 */
    public static OkHttpClient client() {
        return OkHttp.client();
    }

    public void init(Context context) throws Exception {
    }

    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    /**
     * 手机端分支宿主（XBPQ / HBPQ 一系 jar 约定）在 init 之后注入的回调；默认不处理。
     * 由 {@code SpiderApiBinder} 调用。
     */
    public void initApi(SpiderApi api) {
    }

    public String homeContent(boolean filter) throws Exception {
        return "";
    }

    public String homeVideoContent() throws Exception {
        return "";
    }

    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        return "";
    }

    public String detailContent(List<String> ids) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return searchContent(key, quick);
    }

    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return "";
    }

    public String liveContent(String url) throws Exception {
        return "";
    }

    public boolean manualVideoCheck() throws Exception {
        return false;
    }

    public boolean isVideoFormat(String url) throws Exception {
        return false;
    }

    public Object[] proxy(Map<String, String> params) throws Exception {
        return null;
    }

    public String action(String action) throws Exception {
        return null;
    }

    public void destroy() {
        closeHostResources();
    }
}
