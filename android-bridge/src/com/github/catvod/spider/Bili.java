package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.bean.Class;
import com.github.catvod.bean.Result;
import com.github.catvod.bean.Vod;
import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;
import com.github.catvod.utils.Util;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class Bili extends Spider {

    /** 形态一：`data.result` 是视频对象数组（老接口）。 */
    private static final String API_SEARCH_TYPE =
            "/x/web-interface/search/type?search_type=video&keyword=%s&page=%d";
    /** 形态二：`data.result` 是「分组数组」，video 在 `result_type=video` 的 `data` 里。 */
    private static final String API_SEARCH_ALL =
            "/x/web-interface/search/all/v2?keyword=%s&page=%d";

    private String jsonUrl = "";
    private String catalog;

    @Override
    public synchronized void init(Context context, String extend) throws Exception {
        catalog = null;
        jsonUrl = "";
        String value = extend != null ? extend.trim() : "";
        if (value.startsWith("{")) {
            jsonUrl = new JSONObject(value).optString("json", "").trim();
        } else if (value.startsWith("http://") || value.startsWith("https://")) {
            jsonUrl = value;
        }
    }

    @Override
    public synchronized String homeContent(boolean filter) throws Exception {
        if (!jsonUrl.isEmpty()) {
            if (catalog == null) catalog = readCatalog();
            return catalog;
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

    private String readCatalog() throws Exception {
        okhttp3.Request request = new okhttp3.Request.Builder().url(jsonUrl).build();
        try (okhttp3.Response response = OkHttp.client().newCall(request).execute()) {
            if (!response.isSuccessful() || response.body() == null) {
                throw new IOException("Bilibili 分类配置请求失败（HTTP " + response.code() + "）");
            }
            JSONObject data = new JSONObject(response.body().string());
            JSONArray source = data.getJSONArray("class");
            JSONArray categories = new JSONArray();
            for (int i = 0; i < source.length(); i++) {
                JSONObject category = source.optJSONObject(i);
                if (category == null) continue;
                String id = category.optString("type_id", category.optString("id", "")).trim();
                // peizhi 是移动插件的登录操作，桌面分类请求会把它误当成搜索词。
                if (!id.isEmpty() && !id.equals("peizhi")) categories.put(category);
            }
            if (categories.length() == 0) throw new IOException("Bilibili 分类配置没有节目分类");
            return data.put("class", categories).toString();
        }
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        String keyword = (tid != null && !tid.isEmpty()) ? tid : "热门";
        int pageNum = 1;
        try { pageNum = Integer.parseInt(pg); } catch (Exception ignored) {}
        if (extend != null) {
            String selected = extend.getOrDefault("tid", "").trim();
            if (!selected.isEmpty() && !selected.equals("0")) keyword = selected;
        }
        StringBuilder options = new StringBuilder();
        for (String field : Arrays.asList("order", "duration")) {
            String value = extend == null ? "" : extend.getOrDefault(field, "").trim();
            if (!value.isEmpty() && !value.equals("0")) {
                options.append('&').append(field).append('=')
                        .append(URLEncoder.encode(value, StandardCharsets.UTF_8));
            }
        }
        return search(keyword, pageNum, options.toString());
    }

    @Override
    public String detailContent(List<String> ids) throws Exception {
        if (ids == null || ids.isEmpty()) return Result.string(Collections.emptyList());
        String bvid = ids.get(0);
        JSONObject video = requestData("/x/web-interface/view?" + videoQuery(bvid));
        List<String> episodes = new ArrayList<>();
        JSONArray pages = video.optJSONArray("pages");
        if (pages != null) {
            for (int i = 0; i < pages.length(); i++) {
                JSONObject page = pages.optJSONObject(i);
                if (page == null || page.optLong("cid", 0) <= 0) continue;
                String title = page.optString("part", "").trim();
                if (title.isEmpty()) title = "第 " + (i + 1) + " P";
                episodes.add(title.replace('#', '＃').replace('$', '＄')
                        + "$" + bvid + "_" + page.getLong("cid"));
            }
        }
        if (episodes.isEmpty() && video.optLong("cid", 0) > 0) {
            episodes.add("正片$" + bvid + "_" + video.getLong("cid"));
        }
        if (episodes.isEmpty()) throw new IllegalStateException("Bilibili 未返回可播放分 P");

        Vod vod = new Vod();
        vod.setVodId(bvid);
        vod.setVodName(video.optString("title", bvid));
        vod.setVodPic(video.optString("pic", ""));
        vod.setVodRemarks(video.optString("duration", ""));
        vod.setVodContent(video.optString("desc", ""));
        vod.setVodPlayFrom("Bilibili");
        vod.setVodPlayUrl(String.join("#", episodes));

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
        return search(key, pageNum, "");
    }

    private String search(String key, int pageNum, String options) {
        pageNum = Math.max(1, pageNum);
        String keyword = key == null ? "" : key.trim();
        String encoded = URLEncoder.encode(keyword, StandardCharsets.UTF_8);

        List<Vod> list = new ArrayList<>();
        List<String> failures = new ArrayList<>();

        // 形态一（老接口）：data.result 是视频对象数组。
        // 2026-10 起匿名桌面请求普遍被风控：HTTP 412 / {"code":-412,"message":"request was banned"}，
        // 或返回人机验证 HTML（HTTP 200 但不是 JSON）。
        Feed primary = Feed.parse(requestApi(String.format(API_SEARCH_TYPE, encoded, pageNum) + options));
        boolean receivedValidResponse = primary.ok;
        if (primary.ok) {
            list.addAll(primary.videos);
            if (list.isEmpty()) failures.add("search/type 解析到 0 条");
        } else {
            failures.add(primary.describe("search/type"));
        }

        // 形态二（兼容）：data.result 是分组数组，视频在 result_type=video 的 data 里。
        // 关键差异是**层级**变了，元素字段（bvid/title/pic/duration）保持一致。
        if (list.isEmpty()) {
            Feed all = Feed.parse(requestApi(String.format(API_SEARCH_ALL, encoded, pageNum) + options));
            receivedValidResponse |= all.ok;
            if (all.ok) {
                list.addAll(all.videos);
                if (list.isEmpty()) failures.add("search/all/v2 无 video 分组");
            } else {
                failures.add(all.describe("search/all/v2"));
            }
        }

        if (!receivedValidResponse) {
            throw new IllegalStateException("Bilibili 搜索接口不可用：" + String.join("；", failures));
        }
        if (list.isEmpty()) {
            // 有效空结果和接口失败必须分开；另一个接口被限流不应把空搜索变成错误。
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
                JSONObject data = root.optJSONObject("data");
                if (data == null || data.optJSONArray("result") == null) {
                    feed.error = "响应缺少搜索结果";
                    return feed;
                }
                feed.ok = true;
                collect(data, feed.videos);
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
        String[] parts = id.split("_", -1);
        String videoId = parts[0];
        String query = videoQuery(videoId);
        long cid;
        if (parts.length == 1) {
            // 已保存的旧播放记录只有 BV/AV 号，仍解析到该视频的首个分 P。
            JSONObject video = requestData("/x/web-interface/view?" + query);
            cid = video.optLong("cid", 0);
            JSONArray pages = video.optJSONArray("pages");
            if (cid <= 0 && pages != null && pages.length() > 0) {
                cid = pages.getJSONObject(0).optLong("cid", 0);
            }
        } else if (parts.length == 2 && parts[1].matches("[0-9]+")) {
            cid = Long.parseLong(parts[1]);
        } else {
            throw new IllegalArgumentException("Bilibili 播放 ID 格式无效");
        }
        if (cid <= 0) throw new IllegalStateException("Bilibili 未返回可播放分 P");
        JSONObject playback = requestData("/x/player/playurl?" + query + "&cid=" + cid
                + "&qn=64&fnval=1&fnver=0&fourk=0");
        JSONArray urls = playback.optJSONArray("durl");
        if (urls == null || urls.length() == 0) {
            throw new IllegalStateException("Bilibili 未返回直连媒体，可能需要登录或该视频不可播放");
        }
        // 多段 FLV 不能只取第一段，否则界面正常但影片被截断。
        if (urls.length() != 1) throw new IllegalStateException("Bilibili 分段媒体暂不支持直连播放");
        String media = urls.getJSONObject(0).optString("url", "");
        if (!media.startsWith("https://") && !media.startsWith("http://")) {
            throw new IllegalStateException("Bilibili 媒体地址无效");
        }
        Map<String, String> headers = getHeaders();
        headers.put("Referer", "https://www.bilibili.com/video/"
                + (videoId.matches("[0-9]+") ? "av" + videoId : videoId));
        headers.put("Origin", "https://www.bilibili.com");
        return Result.get().parse(0).url(media).header(headers).string();
    }

    protected String requestApi(String path) {
        okhttp3.Request.Builder request = new okhttp3.Request.Builder()
                .url("https://api.bilibili.com" + path);
        getHeaders().forEach(request::header);
        try (okhttp3.Response response = OkHttp.client().newCall(request.build()).execute()) {
            return response.body() == null ? "" : response.body().string();
        } catch (IOException error) {
            return "";
        }
    }

    private JSONObject requestData(String path) {
        String body = requestApi(path);
        JSONObject response;
        try {
            response = new JSONObject(body);
        } catch (org.json.JSONException error) {
            throw new IllegalStateException("Bilibili 返回非 JSON 响应，可能受到访问限制");
        }
        int code = response.optInt("code", -1);
        JSONObject data = response.optJSONObject("data");
        if (code != 0 || data == null) {
            throw new IllegalStateException("Bilibili 接口不可用，code=" + code);
        }
        return data;
    }

    private static String videoQuery(String id) {
        if (id != null && id.matches("BV[0-9A-Za-z]+")) return "bvid=" + id;
        if (id != null && id.matches("(?:av)?[0-9]+")) return "aid=" + id.replaceFirst("^av", "");
        throw new IllegalArgumentException("Bilibili 视频 ID 格式无效");
    }

    private Map<String, String> getHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("User-Agent", Util.CHROME);
        h.put("Referer", "https://www.bilibili.com");
        return h;
    }
}
