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

public class Kanqiu extends Spider {

    private String siteUrl = "https://www.88kanqiu.tv";

    @Override
    public void init(Context context, String extend) {
        if (extend != null && !extend.trim().isEmpty() && (extend.startsWith("http://") || extend.startsWith("https://"))) {
            this.siteUrl = extend.trim();
        }
    }

    @Override
    public String homeContent(boolean filter) {
        List<Class> classes = Arrays.asList(
            new Class("", "全部直播"),
            new Class("1", "篮球直播"),
            new Class("8", "足球直播"),
            new Class("29", "综合体育")
        );
        return Result.get().classes(classes).string();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        String urlPath = (tid == null || tid.isEmpty()) ? "/match" : "/match/" + tid + "/live";
        String html = OkHttp.string(siteUrl + urlPath, getHeaders());
        List<Vod> list = parseHtmlMatches(html);
        return Result.get().vod(list).page(1, 1, list.size(), list.size()).string();
    }

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        String id = ids.get(0);
        String fullUrl = id.startsWith("http") ? id : (siteUrl + (id.startsWith("/") ? "" : "/") + id);
        String html = OkHttp.string(fullUrl, getHeaders());

        Vod vod = new Vod();
        vod.setVodId(id);
        vod.setVodName("直播比赛");
        vod.setVodPlayFrom("88看球");

        StringBuilder playUrl = new StringBuilder();
        Pattern p = Pattern.compile("href=\"([^\"]*play[^\"]*)\"[^>]*>([^<]+)<");
        Matcher m = p.matcher(html);
        int count = 1;
        while (m.find()) {
            if (playUrl.length() > 0) playUrl.append("#");
            String lineUrl = m.group(1);
            String lineName = m.group(2).trim();
            if (!lineUrl.startsWith("http")) lineUrl = siteUrl + (lineUrl.startsWith("/") ? "" : "/") + lineUrl;
            playUrl.append(lineName.isEmpty() ? ("信号" + count) : lineName).append("$").append(lineUrl);
            count++;
        }

        if (playUrl.length() == 0) {
            playUrl.append("高清直播$").append(fullUrl);
        }

        vod.setVodPlayUrl(playUrl.toString());
        return Result.string(vod);
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return Result.get().parse(1).url(id).string();
    }

    private List<Vod> parseHtmlMatches(String html) {
        List<Vod> list = new ArrayList<>();
        if (html == null || html.isEmpty()) return list;

        Pattern p = Pattern.compile("href=\"([^\"]*(?:match|live)[^\"]*)\"[^>]*>\\s*<div[^>]*class=\"[^\"]*team[^\"]*\"[^>]*>([^<]+)<.*?<div[^>]*class=\"[^\"]*team[^\"]*\"[^>]*>([^<]+)<", Pattern.DOTALL);
        Matcher m = p.matcher(html);
        while (m.find()) {
            String link = m.group(1);
            String team1 = m.group(2).trim();
            String team2 = m.group(3).trim();
            String title = team1 + " VS " + team2;
            list.add(new Vod(link, title, "https://pic.imgdb.cn/item/657673d6c458853aeff94ab9.jpg", "直播中"));
        }

        if (list.isEmpty()) {
            Pattern p2 = Pattern.compile("<a[^>]*href=\"([^\"]*(?:match|live)[^\"]*)\"[^>]*>([^<]+)</a>");
            Matcher m2 = p2.matcher(html);
            while (m2.find()) {
                String link = m2.group(1);
                String title = m2.group(2).trim();
                if (title.length() > 2 && !title.contains("首页")) {
                    list.add(new Vod(link, title, "https://pic.imgdb.cn/item/657673d6c458853aeff94ab9.jpg", "进行中"));
                }
            }
        }
        return list;
    }

    private Map<String, String> getHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("User-Agent", Util.CHROME);
        return h;
    }
}
