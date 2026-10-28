package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Class;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;

import java.util.*;

public class Douban extends Spider {

    /**
     * 豆瓣移动版接口。原来的 frodo.douban.com + apiKey 已于 2026-10 起统一返回 400 / 997；
     * rexxar 路径一一对应、JSON 结构相同，只要求浏览器 UA + m.douban.com 的 Referer。
     */
    private static final String REXXAR = "https://m.douban.com/rexxar/api/v2";
    private static final String UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";
    /** FongMi 图片地址的「@头=值」写法：豆瓣图床只带 UA 或只带 Referer 都会 403/418。 */
    private static final String IMAGE_HEADERS = "@Referer=https://m.douban.com/@User-Agent=" + UA;

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

        String json = OkHttp.string(REXXAR + "/subject_collection/movie_showing/items?start=0&count=20", getHeaders());
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
        else if ("tv_variety".equals(tid)) collection = "show_hot"; // rexxar 没有 tv_variety 合集（404）
        else if ("tv_animation".equals(tid)) collection = "tv_animation";

        String url = REXXAR + "/subject_collection/" + collection + "/items?start=" + start + "&count=20";
        String json = OkHttp.string(url, getHeaders());
        List<Vod> list = parseDouban(json);

        return Result.get().vod(list).page(page, 10, list.size(), 200).string();
    }

    @Override
    public String detailContent(List<String> ids) {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        String id = ids.get(0);
        String url = REXXAR + "/movie/" + id;
        String json = OkHttp.string(url, getHeaders());

        Vod vod = new Vod();
        vod.setVodId(id);
        vod.setVodName(id);
        try {
            org.json.JSONObject d = new org.json.JSONObject(json);
            vod.setVodName(d.optString("title", id));
            org.json.JSONObject pic = d.optJSONObject("pic");
            if (pic != null) vod.setVodPic(pic.optString("normal", pic.optString("large")) + IMAGE_HEADERS);
            vod.setVodContent(d.optString("intro"));
            vod.setVodYear(d.optString("year"));
            vod.setVodArea(join(d.optJSONArray("countries"), null));
            vod.setTypeName(join(d.optJSONArray("genres"), null));
            vod.setVodDirector(join(d.optJSONArray("directors"), "name"));
            vod.setVodActor(join(d.optJSONArray("actors"), "name"));
        } catch (Exception ignored) {
            // 非 JSON（风控页 / 网络错误）：只保留 id，界面仍能按片名搜索
        }
        vod.setVodPlayFrom("豆瓣搜索");
        vod.setVodPlayUrl("正片$" + id);

        return Result.string(vod);
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return Result.get().url(id).string();
    }

    /**
     * 解析 rexxar 合集响应。电影条目只有 {@code cover.url}，剧集 / 综艺只有 {@code pic.normal}，两者都认；
     * 缺片名或封面的条目跳过。海报带上图床要求的 Referer / UA（豆瓣图床有防盗链）。
     */
    private List<Vod> parseDouban(String json) {
        List<Vod> list = new ArrayList<>();
        if (json == null || json.isEmpty()) return list;
        try {
            org.json.JSONArray items = new org.json.JSONObject(json).optJSONArray("subject_collection_items");
            if (items == null) return list;
            for (int i = 0; i < items.length(); i++) {
                org.json.JSONObject it = items.optJSONObject(i);
                if (it == null) continue;
                String id = it.optString("id");
                String title = it.optString("title");
                String pic = "";
                org.json.JSONObject picObj = it.optJSONObject("pic");
                if (picObj != null) pic = picObj.optString("normal", picObj.optString("large"));
                if (pic.isEmpty()) {
                    org.json.JSONObject cover = it.optJSONObject("cover");
                    if (cover != null) pic = cover.optString("url");
                }
                if (id.isEmpty() || title.isEmpty() || pic.isEmpty()) continue;
                String remark = "";
                org.json.JSONObject rating = it.optJSONObject("rating");
                if (rating != null && rating.optDouble("value", 0) > 0) remark = "评分：" + rating.optDouble("value");
                list.add(new Vod(id, title, pic + IMAGE_HEADERS, remark));
            }
        } catch (Exception ignored) {
            // 非 JSON（风控页 / 网络错误）按空列表处理
        }
        return list;
    }

    /** 数组拼成「a / b / c」；元素是对象时取 field 字段。 */
    private static String join(org.json.JSONArray arr, String field) {
        if (arr == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < arr.length(); i++) {
            String v = field == null ? arr.optString(i) : (arr.optJSONObject(i) == null ? "" : arr.optJSONObject(i).optString(field));
            if (v.isEmpty()) continue;
            if (sb.length() > 0) sb.append(" / ");
            sb.append(v);
        }
        return sb.toString();
    }

    private Map<String, String> getHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("User-Agent", UA);
        h.put("Referer", "https://m.douban.com/");
        return h;
    }
}
