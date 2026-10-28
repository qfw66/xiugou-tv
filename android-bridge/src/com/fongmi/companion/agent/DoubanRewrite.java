package com.fongmi.companion.agent;

import java.util.Locale;

import okhttp3.HttpUrl;
import okhttp3.Request;

/**
 * 把载荷里已废弃的豆瓣接口改写到仍可用的 rexxar 接口。
 *
 * <p>载荷 {@code Douban} 站（配置里的「免费分享 / 更新日期 / 网盘类先扫码」三个头部站）
 * 访问 {@code frodo.douban.com/api/v2/...?apikey=0ac44…} 与 {@code api.douban.com/api/v2/...}，
 * 2026-10 起统一返回 {@code 400 invalid_request_997}，三站分类全部 0 条。
 *
 * <p>{@code m.douban.com/rexxar/api/v2/...} 与 frodo 路径一一对应、JSON 结构相同
 * （{@code subject_collection_items} / {@code items}，条目带 {@code pic.normal}、{@code rating.value}），
 * 只要求浏览器 UA + {@code Referer: https://m.douban.com/}。实测（2026-10-27）：
 * hot_gaia、movie_real_time_hotest、subject_real_time_hotest、show_hot、tv_hot 均 200。
 * 应用自己的「豆瓣热播」首页早已走 rexxar（见 lib/core/api/douban_repository.dart）。
 */
public final class DoubanRewrite {

    static final String UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";
    static final String REFERER = "https://m.douban.com/";

    private DoubanRewrite() {
    }

    /** 命中废弃接口时返回改写后的请求；否则原样返回同一对象。 */
    public static Request apply(Request request) {
        if (request == null) return null;
        HttpUrl rewritten = rewrite(request.url());
        if (rewritten == null) return request;
        return request.newBuilder()
                .url(rewritten)
                .header("User-Agent", UA)
                .header("Referer", REFERER)
                .removeHeader("Host")
                .build();
    }

    /** frodo / api 的 /api/v2/<path> → m.douban.com/rexxar/api/v2/<path>，去掉 apikey，其余参数保留。 */
    static HttpUrl rewrite(HttpUrl url) {
        if (url == null) return null;
        String host = url.host().toLowerCase(Locale.ROOT);
        if (!host.equals("frodo.douban.com") && !host.equals("api.douban.com")) return null;
        String path = url.encodedPath();
        if (!path.startsWith("/api/v2/")) return null;
        HttpUrl.Builder b = new HttpUrl.Builder()
                .scheme("https")
                .host("m.douban.com")
                .encodedPath("/rexxar" + path);
        for (int i = 0; i < url.querySize(); i++) {
            String name = url.queryParameterName(i);
            if (name.equalsIgnoreCase("apikey")) continue;
            b.addQueryParameter(name, url.queryParameterValue(i));
        }
        return b.build();
    }
}
