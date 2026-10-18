package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.crawler.Spider;

import java.util.HashMap;
import java.util.List;

/**
 * Diagnostic placeholder for Android-native guarded spiders that cannot run on JVM.
 */
public class UnsupportedGuardSpider extends Spider {
    private String message = "该 Android Guard 爬虫依赖 Android/Dex/native 运行时，当前 Windows JVM 伴随服务无法执行";

    @Override
    public void init(Context context, String extend) {
    }

    @Override
    public String homeContent(boolean filter) {
        return response();
    }

    @Override
    public String homeVideoContent() {
        return response();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        return response();
    }

    @Override
    public String detailContent(List<String> ids) {
        return response();
    }

    @Override
    public String searchContent(String key, boolean quick) {
        return response();
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return "{\"url\":\"\",\"msg\":\"" + escape(message) + "\"}";
    }

    private String response() {
        return "{\"class\":[],\"list\":[],\"msg\":\"" + escape(message) + "\"}";
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
