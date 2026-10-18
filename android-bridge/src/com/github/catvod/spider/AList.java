package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Class;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;
import com.github.catvod.utils.Json;
import com.github.catvod.utils.Util;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class AList extends Spider {

    private String siteUrl = "";

    @Override
    public void init(Context context, String extend) {
        if (extend != null && !extend.trim().isEmpty()) {
            if (extend.startsWith("http://") || extend.startsWith("https://")) {
                this.siteUrl = extend.trim();
            } else if (extend.startsWith("{")) {
                this.siteUrl = Json.optString(extend, "url", "");
            }
        }
    }

    @Override
    public String homeContent(boolean filter) {
        List<Class> classes = Arrays.asList(
            new Class("/", "根目录"),
            new Class("/电影", "电影"),
            new Class("/电视剧", "电视剧"),
            new Class("/动漫", "动漫")
        );
        return Result.get().classes(classes).string();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        if (siteUrl.isEmpty()) {
            return Result.get().vod(Collections.emptyList()).string();
        }

        String path = (tid == null || tid.isEmpty()) ? "/" : tid;
        String apiUrl = siteUrl.replaceAll("/+$", "") + "/api/fs/list";
        String reqJson = "{\"path\":\"" + path + "\",\"password\":\"\",\"page\":1,\"per_page\":50,\"refresh\":false}";
        String resp = OkHttp.postJson(apiUrl, reqJson, null);

        List<Vod> list = new ArrayList<>();
        Pattern p = Pattern.compile("\\{\\s*\"name\"\\s*:\\s*\"([^\"]+)\"[^\\}]*\"is_dir\"\\s*:\\s*(true|false)(?:[^\\}]*\"thumb\"\\s*:\\s*\"([^\"]*)\")?");
        Matcher m = p.matcher(resp);
        while (m.find()) {
            String name = m.group(1);
            boolean isDir = "true".equalsIgnoreCase(m.group(2));
            String thumb = m.groupCount() >= 3 && m.group(3) != null ? m.group(3) : "";
            String itemPath = path.endsWith("/") ? (path + name) : (path + "/" + name);

            if (isDir) {
                list.add(new Vod(itemPath, name, thumb, "文件夹"));
            } else if (Util.isMedia(name)) {
                list.add(new Vod(itemPath, name, thumb, "媒体"));
            }
        }

        return Result.get().vod(list).page(1, 1, list.size(), list.size()).string();
    }

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty() || siteUrl.isEmpty()) return Result.string(Collections.emptyList());
        String path = ids.get(0);
        String apiUrl = siteUrl.replaceAll("/+$", "") + "/api/fs/get";
        String reqJson = "{\"path\":\"" + path + "\",\"password\":\"\"}";
        String resp = OkHttp.postJson(apiUrl, reqJson, null);

        String rawUrl = Json.optString(resp, "raw_url", "");
        if (rawUrl.isEmpty()) {
            rawUrl = Json.optString(resp, "url", "");
        }

        Vod vod = new Vod();
        vod.setVodId(path);
        vod.setVodName(path.substring(path.lastIndexOf("/") + 1));
        vod.setVodPlayFrom("AList");
        vod.setVodPlayUrl("播放$" + (rawUrl.isEmpty() ? path : rawUrl));

        return Result.string(vod);
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return Result.get().url(id).string();
    }
}
