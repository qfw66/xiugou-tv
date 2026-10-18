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

/**
 * 糯米影视 / 糯米秒播 Spider (Nmys)
 */
public class Nmys extends Spider {

    private String siteUrl = "https://www.nmys.net";

    @Override
    public void init(Context context, String extend) {
        if (extend != null && !extend.trim().isEmpty() && (extend.startsWith("http://") || extend.startsWith("https://"))) {
            this.siteUrl = extend.trim().replaceAll("/+$", "");
        }
    }

    @Override
    public String homeContent(boolean filter) {
        List<Class> classes = Arrays.asList(
            new Class("1", "电影"),
            new Class("2", "连续剧"),
            new Class("3", "综艺"),
            new Class("4", "动漫"),
            new Class("6", "动作片"),
            new Class("7", "喜剧片"),
            new Class("8", "爱情片"),
            new Class("9", "科幻片")
        );

        // Fetch home recommendations
        String html = OkHttp.string(siteUrl, getHeaders());
        List<Vod> list = parseVodList(html);

        return Result.get().classes(classes).vod(list).string();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        String pageStr = (pg == null || pg.isEmpty()) ? "1" : pg;
        String url = siteUrl + "/vodtype/" + tid + "-" + pageStr + ".html";
        String html = OkHttp.string(url, getHeaders());
        List<Vod> list = parseVodList(html);
        return Result.get().vod(list).page(Integer.parseInt(pageStr), 100, list.size(), 1000).string();
    }

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        String id = ids.get(0);
        String url = id.startsWith("http") ? id : (siteUrl + (id.startsWith("/") ? "" : "/") + id);
        String html = OkHttp.string(url, getHeaders());

        Vod vod = new Vod();
        vod.setVodId(id);
        vod.setVodName(extractRegex(html, "<h1[^>]*>([^<]+)</h1>", "糯米视频"));
        vod.setVodPic(extractRegex(html, "<img[^>]*class=\"[^\"]*lazy[^\"]*\"[^>]*data-original=\"([^\"]+)\"", ""));
        vod.setVodRemarks(extractRegex(html, "<span[^>]*class=\"[^\"]*pic-text[^\"]*\"[^>]*>([^<]+)</span>", ""));
        vod.setVodContent(extractRegex(html, "<span[^>]*class=\"[^\"]*detail-content[^\"]*\"[^>]*>([^<]+)</span>", ""));
        vod.setVodPlayFrom("糯米秒播$$$备用线路");

        StringBuilder playUrls = new StringBuilder();
        Pattern p = Pattern.compile("href=\"([^\"]*vodplay[^\"]*)\"[^>]*>([^<]+)<");
        Matcher m = p.matcher(html);
        while (m.find()) {
            if (playUrls.length() > 0) playUrls.append("#");
            String epUrl = m.group(1);
            String epName = m.group(2).trim();
            if (!epUrl.startsWith("http")) epUrl = siteUrl + (epUrl.startsWith("/") ? "" : "/") + epUrl;
            playUrls.append(epName).append("$").append(epUrl);
        }

        if (playUrls.length() == 0) {
            playUrls.append("正片$").append(url);
        }

        vod.setVodPlayUrl(playUrls + "$$$" + playUrls);
        return Result.string(vod);
    }

    @Override
    public String searchContent(String key, boolean quick) {
        String encoded = URLEncoder.encode(key != null ? key : "", StandardCharsets.UTF_8);
        String url = siteUrl + "/vodsearch/-------------.html?wd=" + encoded;
        String html = OkHttp.string(url, getHeaders());
        List<Vod> list = parseVodList(html);
        return Result.get().vod(list).page(1, 1, list.size(), list.size()).string();
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        if (id == null) return "{}";
        // Sniff or parse HTML for player URL
        String html = OkHttp.string(id, getHeaders());
        String playerUrl = extractRegex(html, "\"url\"\\s*:\\s*\"([^\"]+)\"", "");
        if (!playerUrl.isEmpty()) {
            playerUrl = playerUrl.replace("\\/", "/");
            return Result.get().url(playerUrl).string();
        }
        return Result.get().parse(1).url(id).string();
    }

    private List<Vod> parseVodList(String html) {
        List<Vod> list = new ArrayList<>();
        if (html == null || html.isEmpty()) return list;

        Pattern p = Pattern.compile("<a[^>]*href=\"([^\"]*(?:voddetail|detail)[^\"]*)\"[^>]*title=\"([^\"]+)\"[^>]*>.*?<img[^>]*(?:data-original|src)=\"([^\"]+)\"", Pattern.DOTALL);
        Matcher m = p.matcher(html);
        while (m.find()) {
            String href = m.group(1);
            String title = m.group(2).trim();
            String pic = m.group(3).trim();
            if (!pic.startsWith("http") && !pic.startsWith("//")) pic = siteUrl + (pic.startsWith("/") ? "" : "/") + pic;
            if (pic.startsWith("//")) pic = "https:" + pic;
            list.add(new Vod(href, title, pic, ""));
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
        h.put("User-Agent", Util.CHROME);
        h.put("Referer", siteUrl);
        return h;
    }
}
