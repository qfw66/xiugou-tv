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
 * Universal AppYsV2 Spider for AppYsV2 standard stations.
 */
public class AppYsV2 extends Spider {

    private String siteUrl = "";

    @Override
    public void init(Context context, String extend) {
        if (extend != null && !extend.trim().isEmpty()) {
            if (extend.startsWith("http://") || extend.startsWith("https://")) {
                this.siteUrl = extend.trim().replaceAll("/+$", "");
            } else if (extend.startsWith("{")) {
                this.siteUrl = Json.optString(extend, "siteUrl", Json.optString(extend, "url", "")).replaceAll("/+$", "");
            }
        }
    }

    @Override
    public String homeContent(boolean filter) {
        if (siteUrl.isEmpty()) {
            List<Class> classes = Arrays.asList(
                new Class("1", "电影"),
                new Class("2", "连续剧"),
                new Class("3", "综艺"),
                new Class("4", "动漫")
            );
            return Result.get().classes(classes).string();
        }

        String url = siteUrl + "/api.php/app/nav";
        String json = OkHttp.string(url, getHeaders());

        List<Class> classes = new ArrayList<>();
        Pattern p = Pattern.compile("\"type_id\"\\s*:\\s*\"?(\\d+)\"?\\s*,\\s*\"type_name\"\\s*:\\s*\"([^\"]+)\"");
        Matcher m = p.matcher(json);
        while (m.find()) {
            classes.add(new Class(m.group(1), m.group(2)));
        }

        if (classes.isEmpty()) {
            classes.addAll(Arrays.asList(
                new Class("1", "电影"),
                new Class("2", "连续剧"),
                new Class("3", "综艺"),
                new Class("4", "动漫")
            ));
        }

        return Result.get().classes(classes).string();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        if (siteUrl.isEmpty()) return Result.get().vod(Collections.emptyList()).string();

        String pageStr = (pg == null || pg.isEmpty()) ? "1" : pg;
        String url = siteUrl + "/api.php/app/video?tid=" + tid + "&pg=" + pageStr;
        String json = OkHttp.string(url, getHeaders());

        List<Vod> list = parseAppVods(json);
        return Result.get().vod(list).page(Integer.parseInt(pageStr), 100, list.size(), 1000).string();
    }

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty() || siteUrl.isEmpty()) return Result.string(Collections.emptyList());
        String vodId = ids.get(0);
        String url = siteUrl + "/api.php/app/video_detail?id=" + vodId;
        String json = OkHttp.string(url, getHeaders());

        Vod vod = new Vod();
        vod.setVodId(vodId);
        vod.setVodName(Json.optString(json, "vod_name", "影视详情"));
        vod.setVodPic(Json.optString(json, "vod_pic", ""));
        vod.setVodRemarks(Json.optString(json, "vod_remarks", ""));
        vod.setVodContent(Json.optString(json, "vod_content", ""));
        vod.setVodPlayFrom("默认线路");
        vod.setVodPlayUrl("正片$" + vodId);

        return Result.string(vod);
    }

    @Override
    public String searchContent(String key, boolean quick) {
        if (siteUrl.isEmpty()) return Result.get().vod(Collections.emptyList()).string();

        String encoded = URLEncoder.encode(key != null ? key : "", StandardCharsets.UTF_8);
        String url = siteUrl + "/api.php/app/search?text=" + encoded + "&pg=1";
        String json = OkHttp.string(url, getHeaders());

        List<Vod> list = parseAppVods(json);
        return Result.get().vod(list).page(1, 1, list.size(), list.size()).string();
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return Result.get().parse(1).url(id).string();
    }

    private List<Vod> parseAppVods(String json) {
        List<Vod> list = new ArrayList<>();
        if (json == null || json.isEmpty()) return list;

        Pattern p = Pattern.compile("\"vod_id\"\\s*:\\s*\"?(\\d+)\"?\\s*,\\s*\"vod_name\"\\s*:\\s*\"([^\"]+)\"[^\\}]*\"vod_pic\"\\s*:\\s*\"([^\"]+)\"");
        Matcher m = p.matcher(json);
        while (m.find()) {
            String id = m.group(1);
            String name = m.group(2);
            String pic = m.group(3).replace("\\/", "/");
            list.add(new Vod(id, name, pic));
        }
        return list;
    }

    private Map<String, String> getHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("User-Agent", Util.CHROME);
        return h;
    }
}
