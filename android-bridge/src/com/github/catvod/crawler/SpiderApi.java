package com.github.catvod.crawler;

import com.fongmi.bridge.AndroidBridge;
import com.google.gson.JsonArray;

/**
 * 部分手机端分支（XBPQ / HBPQ 一系 jar）约定的宿主回调接口：宿主在爬虫 init 之后调用
 * {@link Spider#initApi(SpiderApi)} 注入，爬虫用它打日志、取本地服务地址、请求网页解析与批量请求。
 *
 * <p>桌面端没有 WebView 与批量请求服务：{@link #webParse} / {@link #multiReq} 返回 {@code null}，
 * 载荷会按自身逻辑回落到普通抓取。缺少这个类时，引用它的爬虫在 init 阶段直接
 * {@code NoClassDefFoundError}，整站不可用。
 */
public class SpiderApi {
    private static final SpiderApi SHARED = new SpiderApi();

    public static SpiderApi get() {
        return SHARED;
    }

    public void log(String msg) {
        SpiderDebug.log(msg);
    }

    /** 本地服务端口；伴生服务未启动时为空串。 */
    public String getPort() {
        int port = AndroidBridge.port();
        return port > 0 ? String.valueOf(port) : "";
    }

    /** 本地服务根地址（以 {@code /} 结尾）；伴生服务未启动时为空串。 */
    public String getAddress(boolean local) {
        int port = AndroidBridge.port();
        return port > 0 ? "http://127.0.0.1:" + port + "/" : "";
    }

    /** 手机端用 WebView 解析网页；桌面端不支持，返回 {@code null} 让载荷走自身回落逻辑。 */
    public String webParse(String url, String extra) {
        return null;
    }

    /** 手机端批量并发请求；桌面端不支持，返回 {@code null} 让载荷逐个请求。 */
    public String multiReq(JsonArray requests) {
        return null;
    }
}
