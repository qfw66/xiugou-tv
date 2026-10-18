package com.fongmi.companion.selfcheck;

import com.fongmi.companion.DexSpiderLoader;
import com.fongmi.companion.ParseStage;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;
import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 逐站自检：对给定的站点列表跑一遍 `homeContent` + 前几个分类的 `categoryContent`，
 * 给出「有片 / 只有分类 / 完全不可用」的结论。
 *
 * <p>为什么必须分两层统计：`homeContent` 的分类列表**经常是硬编码**的，不联网也能返回；
 * 真正暴露问题（载荷不可用、native 不兼容、源站挂掉）的是 `categoryContent`。
 * 只看分类数会把整站空壳误判成"正常"。
 *
 * <p>每个站点在独立线程里跑并带超时：壳或上游卡住时，超时后放弃该站继续下一站，
 * 不会拖垮整轮自检。
 */
public final class SiteSelfCheck {

    /** 判定结果。 */
    public static final String OK = "OK";             // 分类内确实有内容
    public static final String DEGRADED = "DEGRADED"; // 有分类但首个分类为空
    public static final String FAILED = "FAILED";     // 载荷/爬虫直接不可用
    public static final String TIMEOUT = "TIMEOUT";   // 超出单站预算

    private SiteSelfCheck() {
    }

    /**
     * @param loader        已初始化的加载器（会复用它的解密/类加载缓存）
     * @param sitesJson     `[{"key":"","api":"","ext":"","jar":""}, ...]`
     * @param maxSites      最多探测多少站（0 = 全部）
     * @param maxCategories 每站最多试几个分类（建议 2~3）
     * @param timeoutSeconds 单站预算（建议 20~45）
     * @return JSON 报告
     */
    public static String run(DexSpiderLoader loader, String sitesJson,
                             int maxSites, int maxCategories, int timeoutSeconds) throws Exception {
        List<JSONObject> sites = parseSites(sitesJson);
        if (maxSites > 0 && sites.size() > maxSites) {
            sites = sites.subList(0, maxSites);
        }

        JSONArray rows = new JSONArray();
        int ok = 0, degraded = 0, failed = 0, timeout = 0;

        for (JSONObject site : sites) {
            String key = site.optString("key", "");
            String api = site.optString("api", "");
            String ext = site.optString("ext", "");
            String jar = site.optString("jar", "");

            JSONObject row = new JSONObject();
            row.put("key", key);
            row.put("api", api);
            long t0 = System.currentTimeMillis();
            String verdict;
            int classes = 0;
            int best = 0;
            String error = "";
            String stage = "";

            ExecutorService ex = newExecutor();
            try {
                Future<Probe> future = ex.submit(() -> probeSite(loader, key, api, ext, jar, maxCategories));
                Probe p = future.get(Math.max(5, timeoutSeconds), TimeUnit.SECONDS);
                classes = p.classes;
                best = p.best;
                error = p.error;
                stage = p.stage != null ? p.stage : "";
                verdict = p.error != null ? FAILED : (best > 0 ? OK : (classes > 0 ? DEGRADED : FAILED));
            } catch (java.util.concurrent.TimeoutException te) {
                verdict = TIMEOUT;
                error = "timeout " + timeoutSeconds + "s";
            } catch (Throwable t) {
                verdict = FAILED;
                Throwable cause = (t.getCause() != null) ? t.getCause() : t;
                error = cause.getClass().getSimpleName() + ": " + trim(cause.getMessage(), 160);
            } finally {
                ex.shutdownNow();
            }

            row.put("verdict", verdict);
            row.put("classes", classes);
            row.put("best", best);
            row.put("ms", System.currentTimeMillis() - t0);
            if (stage != null && !stage.isEmpty()) {
                row.put("stage", stage);
            }
            if (error != null && !error.isEmpty()) {
                row.put("error", error);
            }
            rows.put(row);

            switch (verdict) {
                case OK: ok++; break;
                case DEGRADED: degraded++; break;
                case TIMEOUT: timeout++; break;
                default: failed++; break;
            }
        }

        JSONObject summary = new JSONObject();
        summary.put("total", sites.size());
        summary.put("ok", ok);
        summary.put("degraded", degraded);
        summary.put("failed", failed);
        summary.put("timeout", timeout);

        JSONObject out = new JSONObject();
        out.put("summary", summary);
        out.put("sites", rows);
        return out.toString();
    }

    /** 单站探测结果。 */
    private static final class Probe {
        int classes;
        int best;
        String error;
        /** 失败阶段（下载/解密/代理/类/…），失败时才有值。 */
        String stage;
    }

    private static Probe probeSite(DexSpiderLoader loader, String key, String api,
                                   String ext, String jar, int maxCategories) {
        ParseStage.begin("selfcheck:" + key);
        Probe p = new Probe();
        Spider spider;
        try {
            spider = loader.getSpider(key, api, ext, jar);
        } catch (Throwable t) {
            p.stage = currentStage();
            p.error = t.getClass().getSimpleName() + ": " + trim(t.getMessage(), 120);
            return p;
        }
        if (spider == null || spider instanceof SpiderNull) {
            p.stage = currentStage();
            // 面向用户只说「暂不可用」；具体阶段与原因在 stage / 日志里（不渲染到界面）
            p.error = "站点暂不可用";
            return p;
        }

        String home;
        try {
            home = spider.homeContent(true);
        } catch (Throwable t) {
            p.stage = currentStage();
            p.error = t.getClass().getSimpleName() + ": " + trim(t.getMessage(), 120);
            return p;
        }

        JSONObject h = asObject(home);
        JSONArray classes = h.optJSONArray("class");
        p.classes = classes != null ? classes.length() : 0;

        // 第一个分类常常是"登陆配置/配置中心"，跳过这类再试，否则会把可用站误判成空。
        List<String> tids = new ArrayList<>();
        if (classes != null) {
            for (int i = 0; i < classes.length(); i++) {
                JSONObject c = classes.optJSONObject(i);
                if (c == null) continue;
                String tid = c.optString("type_id", "");
                String name = c.optString("type_name", "");
                if (tid.isEmpty()) continue;
                if (looksLikeConfig(tid) || looksLikeConfig(name)) continue;
                tids.add(tid);
                if (tids.size() >= Math.max(1, maxCategories)) break;
            }
        }

        for (String tid : tids) {
            try {
                String cat = spider.categoryContent(tid, "1", true, new HashMap<>());
                JSONObject cj = asObject(cat);
                JSONArray list = cj.optJSONArray("list");
                int n = list != null ? list.length() : 0;
                if (n > p.best) p.best = n;
                if (p.best > 0) break;   // 已经证明有内容，不必再试
            } catch (Throwable ignored) {
                // 单个分类失败不影响结论；继续试下一个
            }
        }
        return p;
    }

    private static String currentStage() {
        ParseStage.Failure failure = ParseStage.current();
        return failure != null ? failure.stage : "";
    }

    private static boolean looksLikeConfig(String s) {
        if (s == null) return false;
        String t = s.toLowerCase(java.util.Locale.ROOT);
        return t.contains("peizhi") || t.contains("config") || s.contains("配置") || s.contains("登陆") || s.contains("登录");
    }

    private static JSONObject asObject(String json) {
        if (json == null || json.trim().isEmpty()) {
            return new JSONObject();
        }
        try {
            return new JSONObject(json);
        } catch (Throwable t) {
            return new JSONObject();
        }
    }

    private static List<JSONObject> parseSites(String sitesJson) {
        List<JSONObject> out = new ArrayList<>();
        if (sitesJson == null || sitesJson.trim().isEmpty()) {
            return out;
        }
        try {
            JSONArray arr = new JSONArray(sitesJson);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o != null) out.add(o);
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    private static ExecutorService newExecutor() {
        AtomicInteger seq = new AtomicInteger();
        ThreadFactory tf = r -> {
            Thread t = new Thread(r, "selfcheck-" + seq.incrementAndGet());
            t.setDaemon(true);
            return t;
        };
        return Executors.newSingleThreadExecutor(tf);
    }

    private static String trim(String s, int max) {
        if (s == null) return "";
        return s.length() <= max ? s : s.substring(0, max) + "…";
    }
}
