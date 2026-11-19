package com.fongmi.companion;

import com.github.catvod.crawler.Spider;
import java.io.File;
import java.io.IOException;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Adapts CatVod Open Node HTTP routes to the existing Java Spider contract. */
public final class CatNodeSpider extends Spider {
    private final CatNodeRuntime.Source source;
    private final File root;
    private final long epoch = CatNodeRuntime.epoch();
    private CatNodeRuntime runtime;
    private String initializedRevision;
    private volatile boolean destroyed;

    private CatNodeSpider(CatNodeRuntime.Source source, File root) {
        this.source = source; this.root = root;
    }

    public static CatNodeSpider create(String api, String ext, File root) throws IOException {
        return "catnode".equals(api) ? new CatNodeSpider(CatNodeRuntime.Source.from(ext), root) : null;
    }

    @Override public void init(android.content.Context context, String extend) {
        acquire();
    }

    @FunctionalInterface
    private interface RuntimeCall<T> { T run(CatNodeRuntime value) throws Exception; }

    private <T> T withRuntime(RuntimeCall<T> operation) throws Exception {
        CatNodeRuntime candidate;
        java.util.concurrent.locks.Lock held = null;
        try {
            synchronized (this) {
                if (destroyed || epoch != CatNodeRuntime.epoch()) throw new IllegalStateException("Cat site has been closed");
                candidate = runtime;
                while (true) {
                    if (candidate == null || !candidate.isAlive()) candidate = CatNodeRuntime.acquire(source, root, epoch);
                    if (!settings()) candidate = candidate.refreshed(epoch);
                    java.util.concurrent.locks.Lock lease = candidate.readLease();
                    lease.lockInterruptibly();
                    held = lease;
                    if (!candidate.isAlive()) { held.unlock(); held = null; continue; }
                    if (destroyed || Thread.currentThread().isInterrupted()) throw new IOException("Cat site cancelled");
                    String revision = settings() ? "" : candidate.siteRevision(source.route);
                    if (!settings() && (candidate != runtime || !revision.equals(initializedRevision))) {
                        try {
                            candidate.request(source.route + "/init",
                                    Map.of("ext", source.siteExt == null ? "" : source.siteExt));
                        } catch (CatNodeHttpException error) {
                            if (!error.missingRoute) throw error;
                        }
                    }
                    runtime = candidate;
                    initializedRevision = revision;
                    break;
                }
            }
            // Keep the bundle lease through the call, but allow this site's other
            // content calls to share it once initialization is complete.
            return operation.run(candidate);
        } finally { if (held != null) held.unlock(); }
    }

    private CatNodeRuntime acquire() {
        try { return withRuntime(value -> value); }
        catch (Exception error) {
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            throw new IllegalStateException("猫源初始化失败：" + error.getMessage(), error);
        }
    }

    private String call(String method, Map<String,Object> params) {
        try { return withRuntime(value -> value.request(source.route + "/" + method, params)); }
        catch (Exception error) {
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            throw new IllegalStateException("猫源调用失败：" + error.getMessage(), error);
        }
    }

    private static boolean missingRoute(Throwable error) {
        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
            if (cause instanceof CatNodeHttpException response) return response.missingRoute;
        }
        return false;
    }

    private boolean settings() { return "@settings".equals(source.route); }
    int runtimePort() { return acquire().port(); }

    @Override public String homeContent(boolean filter) {
        if (settings()) return settingsDetail();
        return call("home", Map.of("filter", filter));
    }

    @Override public String homeVideoContent() {
        if (settings()) return settingsDetail();
        try { return call("homeVod", Map.of()); }
        catch (IllegalStateException missing) {
            if (!missingRoute(missing)) throw missing;
            try { return call("homeVideo", Map.of()); }
            catch (IllegalStateException fallback) {
                if (!missingRoute(fallback)) throw fallback;
                return "{\"list\":[]}";
            }
        }
    }

    @Override public String categoryContent(String tid, String pg, boolean filter, HashMap<String,String> extend) {
        if (settings()) return settingsDetail();
        return call("category", Map.of("id", tid, "page", page(pg), "filter", filter,
                "filters", extend == null ? Map.of() : extend));
    }

    @Override public String detailContent(List<String> ids) {
        if (settings()) return settingsDetail();
        return call("detail", Map.of("id", ids == null || ids.isEmpty() ? "" : ids.get(0)));
    }

    @Override public String playerContent(String flag, String id, List<String> vipFlags) {
        if (settings()) throw new IllegalStateException("配置入口不可播放");
        return call("play", Map.of("flag", flag, "id", id, "flags", vipFlags == null ? List.of() : vipFlags));
    }

    @Override public String searchContent(String key, boolean quick) { return searchContent(key, quick, "1"); }

    @Override public String searchContent(String key, boolean quick, String pg) {
        if (settings()) return "{\"list\":[]}";
        return call("search", Map.of("wd", key, "quick", quick, "page", page(pg)));
    }

    private String settingsDetail() {
        Map<String,Object> item = new LinkedHashMap<>();
        item.put("vod_id", "cat-settings"); item.put("vod_name", "猫源网页配置"); item.put("vod_pic", "");
        item.put("vod_content", "请在本机网页完成站点和网盘配置：" + acquire().configUrl()
                + "\n配置保存在当前猫源独立目录。完成后返回应用刷新站点。不要向他人发送 Cookie 或 Token。");
        return JsonCodec.stringify(Map.of("list", List.of(item)));
    }

    @Override public void destroy() { destroyed = true; }

    private static int page(String value) {
        try { return Math.max(1, Integer.parseInt(value)); }
        catch (RuntimeException ignored) { return 1; }
    }
}
