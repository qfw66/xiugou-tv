package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Class;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;
import com.github.catvod.utils.Json;
import com.github.catvod.utils.Util;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Bili extends Spider {

    private String jsonUrl = "";
    private String rawExtend = "";

    @Override
    public void init(Context context, String extend) {
        this.rawExtend = extend != null ? extend.trim() : "";
        if (rawExtend.startsWith("{")) {
            this.jsonUrl = Json.optString(rawExtend, "json", "");
        } else if (rawExtend.startsWith("http://") || rawExtend.startsWith("https://")) {
            this.jsonUrl = rawExtend;
        }
    }

    @Override
    public String homeContent(boolean filter) throws Exception {
        if (!jsonUrl.isEmpty()) {
            String remoteJson = OkHttp.string(jsonUrl);
            if (remoteJson != null && remoteJson.trim().startsWith("{")) {
                return remoteJson;
            }
        }

        List<Class> classes = Arrays.asList(
            new Class("纪录片", "纪录片"),
            new Class("电影", "电影"),
            new Class("电视剧", "电视剧"),
            new Class("动画", "动画"),
            new Class("音乐", "音乐"),
            new Class("知识", "知识")
        );
        return Result.get().classes(classes).string();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        String keyword = (tid != null && !tid.isEmpty()) ? tid : "热门";
        int pageNum = 1;
        try { pageNum = Integer.parseInt(pg); } catch (Exception ignored) {}
        return searchContent(keyword, false, String.valueOf(pageNum));
    }

    @Override
    public String detailContent(List<String> ids) throws Exception {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        String bvid = ids.get(0);
        String url = "https://api.bilibili.com/x/web-interface/view?bvid=" + bvid;
        String json = OkHttp.string(url, getHeaders());

        Vod vod = new Vod();
        vod.setVodId(bvid);
        vod.setVodName(Json.optString(json, "title", bvid));
        vod.setVodPic(Json.optString(json, "pic", ""));
        vod.setVodRemarks(Json.optString(json, "duration", ""));
        vod.setVodContent(Json.optString(json, "desc", ""));
        vod.setVodPlayFrom("Bilibili");
        vod.setVodPlayUrl("高清$" + bvid);

        return Result.string(vod);
    }

    @Override
    public String searchContent(String key, boolean quick) throws Exception {
        return searchContent(key, quick, "1");
    }

    public String searchContent(String key, boolean quick, String pg) throws Exception {
        String encoded = URLEncoder.encode(key != null ? key : "", StandardCharsets.UTF_8);
        String url = "https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=" + encoded + "&page=" + pg;
        String json = OkHttp.string(url, getHeaders());

        List<Vod> list = new ArrayList<>();
        if (json != null && !json.isEmpty()) {
            Pattern p = Pattern.compile("\\{\\s*\"type\"\\s*:\\s*\"video\"[^\\}]*\"bvid\"\\s*:\\s*\"([^\"]+)\"[^\\}]*\"title\"\\s*:\\s*\"([^\"]+)\"[^\\}]*\"pic\"\\s*:\\s*\"([^\"]+)\"[^\\}]*\"duration\"\\s*:\\s*\"([^\"]*)\"");
            Matcher m = p.matcher(json);
            while (m.find()) {
                String bvid = m.group(1);
                String title = m.group(2).replaceAll("<[^>]*>", "").replaceAll("&quot;", "\"");
                String pic = m.group(3).startsWith("//") ? "https:" + m.group(3) : m.group(3);
                String duration = m.group(4);
                Vod vod = new Vod(bvid, title, pic, duration);
                list.add(vod);
            }
        }

        return Result.get().vod(list).page(Integer.parseInt(pg), 10, list.size(), 100).string();
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        String playUrl = "https://www.bilibili.com/video/" + id;
        return Result.get().parse(1).url(playUrl).string();
    }

    private Map<String, String> getHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("User-Agent", Util.CHROME);
        h.put("Referer", "https://www.bilibili.com");
        return h;
    }
}
