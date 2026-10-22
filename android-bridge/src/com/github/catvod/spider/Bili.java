package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Class;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;
import com.github.catvod.utils.Json;
import com.github.catvod.utils.Util;
import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class Bili extends Spider {

    /** 形态一：`data.result` 是视频对象数组（老接口）。 */
    private static final String API_SEARCH_TYPE =
            "https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=%s&page=%d";
    /** 形态二：`data.result` 是「分组数组」，video 在 `result_type=video` 的 `data` 里。 */
    private static final String API_SEARCH_ALL =
            "https://api.bilibili.com/x/web-interface/search/all/v2?keyword=%s&page=%d";

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
        int pageNum = 1;
        try {
            pageNum = Math.max(1, Integer.parseInt(pg));
        } catch (Exception ignored) {
        }
        String keyword = key == null ? "" : key.trim();
        String encoded = URLEncoder.encode(keyword, StandardCharsets.UTF_8);

        List<Vod> list = new ArrayList<>();
        List<String> failures = new ArrayList<>();

        // 形态一（老接口）：data.result 是视频对象数组。
        // 2026-10 起匿名桌面请求普遍被风控：HTTP 412 / {"code":-412,"message":"request was banned"}，
        // 或返回人机验证 HTML（HTTP 200 但不是 JSON）。
        Feed primary = Feed.parse(OkHttp.string(String.format(API_SEARCH_TYPE, encoded, pageNum), getHeaders()));
        if (primary.ok) {
            list.addAll(primary.videos);
            if (list.isEmpty()) failures.add("search/type 解析到 0 条");
        } else {
            failures.add(primary.describe("search/type"));
        }

        // 形态二（兼容）：data.result 是分组数组，视频在 result_type=video 的 data 里。
        // 关键差异是**层级**变了，元素字段（bvid/title/pic/duration）保持一致。
        if (list.isEmpty()) {
            Feed all = Feed.parse(OkHttp.string(String.format(API_SEARCH_ALL, encoded, pageNum), getHeaders()));
            if (all.ok) {
                list.addAll(all.videos);
                if (list.isEmpty()) failures.add("search/all/v2 无 video 分组");
            } else {
                failures.add(all.describe("search/all/v2"));
            }
        }

        if (list.isEmpty()) {
            // 不能静默返回空列表：否则调用方拿到 {"list":[],"total":100} 会误判成「站点没内容」。
            System.err.println("[Bili] 搜索未取到影片 keyword=" + keyword + " page=" + pageNum
                    + " 原因: " + String.join("；", failures));
        } else if (!failures.isEmpty()) {
            System.err.println("[Bili] 搜索已降级命中 keyword=" + keyword + " page=" + pageNum
                    + " 命中=" + list.size() + " 原因: " + String.join("；", failures));
        }

        return Result.get().vod(list).page(pageNum, 10, list.size(), 100).string();
    }

    /**
     * 两种搜索接口的响应解析：先校验 code，再按「扁平数组 / 分组数组」两种层级取视频。
     *
     * <p>旧实现用正则直接扫原始 JSON 文本，隐含假设了 `type → bvid → title → pic → duration`
     * 的字段顺序且不校验 code；接口一换形态或返回风控页就静默得到空列表。
     */
    private static final class Feed {

        final List<Vod> videos = new ArrayList<>();
        boolean ok;
        String error = "";

        static Feed parse(String body) {
            Feed feed = new Feed();
            String text = body == null ? "" : body.trim();
            if (text.isEmpty()) {
                feed.error = "响应为空（请求未发出或被服务端直接断开）";
                return feed;
            }
            if (!text.startsWith("{")) {
                feed.error = "非 JSON 响应，疑似风控/人机验证页（长度 " + text.length() + "）";
                return feed;
            }
            try {
                JSONObject root = new JSONObject(text);
                int code = root.optInt("code", -1);
                if (code != 0) {
                    feed.error = "code=" + code + " message=" + root.optString("message", "");
                    return feed;
                }
                feed.ok = true;
                collect(root.optJSONObject("data"), feed.videos);
            } catch (Exception e) {
                feed.error = "JSON 解析失败: " + e.getMessage();
            }
            return feed;
        }

        private static void collect(JSONObject data, List<Vod> out) {
            if (data == null) return;
            JSONArray result = data.optJSONArray("result");
            if (result == null) return;
            for (int i = 0; i < result.length(); i++) {
                JSONObject node = result.optJSONObject(i);
                if (node == null) continue;
                if ("video".equals(node.optString("result_type", ""))) {
                    JSONArray group = node.optJSONArray("data");
                    if (group == null) continue;
                    for (int j = 0; j < group.length(); j++) add(out, group.optJSONObject(j));
                } else if (node.has("bvid") || node.has("aid")) {
                    add(out, node);
                }
            }
        }

        private static void add(List<Vod> out, JSONObject item) {
            if (item == null) return;
            // 视频分组里会混入 type=live_room 的直播卡片（bvid 为空、aid=0），
            // 它没有可点播的 bvid，硬塞进去只会得到 vod_id="0" 的死条目。
            String bvid = item.optString("bvid", "");
            String id = bvid;
            if (id.isEmpty() && "video".equals(item.optString("type", ""))) {
                Object aid = item.opt("aid");
                String aidText = aid == null ? "" : String.valueOf(aid);
                if (!aidText.isEmpty() && !"0".equals(aidText)) id = aidText;
            }
            if (id.isEmpty()) return;
            String name = cleanTitle(item.optString("title", item.optString("name", "")));
            String pic = item.optString("pic", item.optString("cover", ""));
            if (pic.startsWith("//")) pic = "https:" + pic;
            out.add(new Vod(id, name, pic, item.optString("duration", "")));
        }

        String describe(String source) {
            return source + " 不可用(" + error + ")";
        }
    }

    /** 搜索标题带 `<em class="keyword">` 高亮与 HTML 实体，需还原成纯文本。 */
    private static String cleanTitle(String text) {
        if (text == null || text.isEmpty()) return "";
        String out = text.replaceAll("<[^>]+>", "");
        out = out.replace("&quot;", "\"")
                .replace("&#39;", "'")
                .replace("&apos;", "'")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&nbsp;", " ")
                .replace("&amp;", "&");
        return out.trim();
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
