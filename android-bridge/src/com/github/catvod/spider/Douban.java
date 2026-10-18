package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Class;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;
import com.github.catvod.utils.Util;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Douban extends Spider {

    @Override
    public void init(Context context, String extend) {}

    @Override
    public String homeContent(boolean filter) {
        List<Class> classes = Arrays.asList(
            new Class("movie_hot", "热门电影"),
            new Class("tv_hot", "热播剧集"),
            new Class("tv_variety", "热门综艺"),
            new Class("tv_animation", "热门动漫")
        );

        String json = OkHttp.string("https://frodo.douban.com/api/v2/subject_collection/movie_showing/items?start=0&count=20&apiKey=0ac44ae016490db2204ce0a042db2916", getHeaders());
        List<Vod> list = parseDouban(json);

        return Result.get().classes(classes).vod(list).string();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        int page = 1;
        try { page = Integer.parseInt(pg); } catch (Exception ignored) {}
        int start = (page - 1) * 20;

        String collection = "movie_showing";
        if ("tv_hot".equals(tid)) collection = "tv_hot";
        else if ("tv_variety".equals(tid)) collection = "tv_variety";
        else if ("tv_animation".equals(tid)) collection = "tv_animation";

        String url = "https://frodo.douban.com/api/v2/subject_collection/" + collection + "/items?start=" + start + "&count=20&apiKey=0ac44ae016490db2204ce0a042db2916";
        String json = OkHttp.string(url, getHeaders());
        List<Vod> list = parseDouban(json);

        return Result.get().vod(list).page(page, 10, list.size(), 200).string();
    }

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        String id = ids.get(0);
        String url = "https://frodo.douban.com/api/v2/movie/" + id + "?apiKey=0ac44ae016490db2204ce0a042db2916";
        String json = OkHttp.string(url, getHeaders());

        Vod vod = new Vod();
        vod.setVodId(id);
        vod.setVodName(extractRegex(json, "\"title\"\\s*:\\s*\"([^\"]+)\"", id));
        vod.setVodPic(extractRegex(json, "\"normal\"\\s*:\\s*\"([^\"]+)\"", ""));
        vod.setVodContent(extractRegex(json, "\"intro\"\\s*:\\s*\"([^\"]+)\"", ""));
        vod.setVodPlayFrom("豆瓣搜索");
        vod.setVodPlayUrl("正片$" + id);

        return Result.string(vod);
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return Result.get().url(id).string();
    }

    private List<Vod> parseDouban(String json) {
        List<Vod> list = new ArrayList<>();
        if (json == null || json.isEmpty()) return list;

        Pattern p = Pattern.compile("\"id\"\\s*:\\s*\"?(\\d+)\"?\\s*,[^\\]]*?\"title\"\\s*:\\s*\"([^\"]+)\"[^\\]]*?\"cover\"\\s*:\\s*\\{[^\\}]*?\"url\"\\s*:\\s*\"([^\"]+)\"");
        Matcher m = p.matcher(json);
        while (m.find()) {
            String id = m.group(1);
            String title = m.group(2);
            String pic = m.group(3).replace("\\/", "/");
            list.add(new Vod(id, title, pic, ""));
        }
        return list;
    }

    private String extractRegex(String content, String regex, String def) {
        if (content == null) return def;
        Pattern p = Pattern.compile(regex);
        Matcher m = p.matcher(content);
        if (m.find()) {
            return m.group(1).trim();
        }
        return def;
    }

    private Map<String, String> getHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.38");
        return h;
    }
}
