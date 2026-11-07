package com.fongmi.companion.py;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;

/**
 * py 源在 companion 里的代理对象：把 CatVod {@code Spider} 的方法调用转发给子进程里的脚本。
 *
 * <p>契约差异只有一处：{@code Spider} 的方法返回 **JSON 文本**，而脚本返回 dict/list，
 * 由 {@link PyRuntime#callJson} 负责序列化。
 *
 * <p>加载失败不抛异常（否则一个坏脚本会拖垮整份配置的加载），只记录原因；
 * 真正被调用时才报错，与 {@code UnsupportedGuardSpider} 的处理口径一致。
 */
public final class PySpider extends com.github.catvod.crawler.Spider {

    private final String api;
    private final String defaultExt;
    private final File cacheDir;
    private final String scriptSiteKey;
    private final String scriptProxyBase;
    private final String scriptDanmakuBase;
    private final String proxyToken = java.util.UUID.randomUUID().toString();
    private volatile boolean destroyed;
    private final Object startupLifecycle = new Object();
    private Thread startingThread;

    /** 死亡 / 加载失败后的最多重启次数：坏脚本不该被无限拉起（被进程池淘汰不计入）。 */
    static final int MAX_RESTARTS = 3;

    private volatile PyRuntime runtime;
    private String unavailable;
    private String ext;
    private int restarts;
    /** 被进程池淘汰（不是死亡）：下次使用直接重启，不消耗重启次数。 */
    private boolean evicted;
    /** 进行中的调用数：大于 0 时不可被进程池淘汰，否则会把正在跑的请求掐断。 */
    private final java.util.concurrent.atomic.AtomicInteger inFlight = new java.util.concurrent.atomic.AtomicInteger();

    public PySpider(String api, String ext, File cacheDir) {
        this(api, ext, cacheDir, "", "");
    }

    public PySpider(String api, String ext, File cacheDir, String siteKey, String proxyBase) {
        this(api, ext, cacheDir, siteKey, proxyBase, "");
    }

    public PySpider(String api, String ext, File cacheDir, String siteKey, String proxyBase, String danmakuBase) {
        this.api = api == null ? "" : api.trim();
        this.defaultExt = ext == null ? "" : ext;
        this.ext = this.defaultExt;
        this.cacheDir = cacheDir;
        this.scriptSiteKey = siteKey == null ? "" : siteKey;
        this.scriptProxyBase = proxyBase == null || proxyBase.isEmpty() ? ""
                : proxyBase + "?token=" + proxyToken;
        this.scriptDanmakuBase = danmakuBase == null || danmakuBase.isEmpty() ? ""
                : danmakuBase + "?token=" + proxyToken;
    }

    public String proxyToken() { return proxyToken; }
    public String scriptSiteKey() { return scriptSiteKey; }

    /** api 是否指向 Python 脚本。 */
    public static boolean isPythonApi(String api) {
        if (api == null) return false;
        String a = api.trim().toLowerCase(Locale.ROOT);
        if (a.isEmpty()) return false;
        int cut = a.length();
        int q = a.indexOf('?');
        if (q >= 0) cut = q;
        int h = a.indexOf('#');
        if (h >= 0 && h < cut) cut = h;
        return a.substring(0, cut).endsWith(".py");
    }

    // ------------------------------------------------------------------ 生命周期

    @Override
    public void init(android.content.Context context, String extend) {
        ext = extend == null || extend.isEmpty() ? defaultExt : extend;
        synchronized (this) {
            startRuntime();
        }
    }

    /** 拉起子进程；失败只记录原因（见类注释）。调用方须持有 this 锁。 */
    private void startRuntime() {
        synchronized (startupLifecycle) {
            if (destroyed || Thread.currentThread().isInterrupted()) return;
            startingThread = Thread.currentThread();
        }
        try {
            File script = PyRuntime.ensureScript(api, cacheDir);
            if (destroyed || Thread.currentThread().isInterrupted()) return;
            File log = new File(cacheDir, "py-" + PyRuntime.md5(api) + ".log");
            runtime = PyRuntime.start(script, ext, log, scriptSiteKey, api, scriptProxyBase, scriptDanmakuBase);
            if (destroyed) {
                runtime.close();
                runtime = null;
                return;
            }
            unavailable = null;
            System.out.println("[PySpider] ready: " + api + " -> " + script.getName());
            // Registration and retirement share this short lock; the pool evicts asynchronously.
            synchronized (startupLifecycle) {
                if (!destroyed) PyProcessPool.admitLater(this);
            }
        } catch (Throwable t) {
            runtime = null;
            unavailable = String.valueOf(t);
            System.err.println("[PySpider] 不可用 " + api + " : " + t);
        } finally {
            synchronized (startupLifecycle) { startingThread = null; }
        }
    }

    /**
     * 取可用的运行时：存活直接用；死亡 / 加载失败按次数惰性重启；被进程池淘汰则直接重启。
     */
    private synchronized PyRuntime acquire() {
        if (destroyed || Thread.currentThread().isInterrupted()) {
            throw new IllegalStateException("script instance is no longer active");
        }
        if (runtime != null && runtime.isAlive()) return runtime;
        if (runtime != null) {
            runtime.close();
            runtime = null;
        }
        if (!evicted) {
            if (restarts >= MAX_RESTARTS) {
                throw new IllegalStateException("py 源不可用: " + api + "（已重启 " + restarts + " 次）"
                        + (unavailable == null ? "" : " (" + unavailable + ")"));
            }
            restarts++;
            System.err.println("[PySpider] 子进程不可用，第 " + restarts + " 次重启: " + api);
        }
        evicted = false;
        startRuntime();
        if (runtime == null) {
            throw new IllegalStateException("py 源不可用: " + api
                    + (unavailable == null ? "" : " (" + unavailable + ")"));
        }
        return runtime;
    }

    /** 进程池淘汰：仅在没有进行中调用时关闭子进程；返回是否真的关闭了。 */
    synchronized boolean evictIdle() {
        if (inFlight.get() > 0 || runtime == null) return false;
        runtime.close();
        runtime = null;
        evicted = true;
        System.out.println("[PySpider] 进程数达上限，淘汰最久未用: " + api);
        return true;
    }

    synchronized boolean hasLiveRuntime() {
        return runtime != null && runtime.isAlive();
    }

    @Override
    public void destroy() {
        synchronized (startupLifecycle) {
            destroyed = true;
            // A proxy may be restarting an evicted child outside the RPC watchdog registry.
            // Interrupt while holding the registration lock so the thread cannot be reused first.
            if (startingThread != null && startingThread != Thread.currentThread()) startingThread.interrupt();
        }
        PyProcessPool.forget(this);
        // Do not wait for init's monitor. A process still starting is closed by its interrupted
        // startup path; one published concurrently is closed by startRuntime's destroyed check.
        PyRuntime current = runtime;
        if (current != null) current.close();
    }

    // ------------------------------------------------------------------ 转发

    private String call(String method, Object... args) throws Exception {
        inFlight.incrementAndGet();
        try {
            PyRuntime rt = acquire();
            synchronized (startupLifecycle) {
                if (destroyed) throw new IllegalStateException("script instance is no longer active");
                PyProcessPool.touch(this);
            }
            // 脚本没实现的可选方法（liveContent / action / homeVideoContent 等）按基类默认返回 null
            if (!rt.hasMethod(method)) return null;
            return rt.callJson(method, args == null ? new ArrayList<>() : Arrays.asList(args));
        } finally {
            inFlight.decrementAndGet();
        }
    }

    @Override
    public String homeContent(boolean filter) throws Exception {
        return call("homeContent", filter);
    }

    @Override
    public String homeVideoContent() throws Exception {
        return call("homeVideoContent");
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter,
                                  HashMap<String, String> extend) throws Exception {
        return call("categoryContent", tid, pg, filter, extend);
    }

    @Override
    public String detailContent(List<String> ids) throws Exception {
        return call("detailContent", ids);
    }

    @Override
    public String searchContent(String key, boolean quick) throws Exception {
        // 脚本侧签名两种都有（2 参 / 3 参），统一按最多传，runner 按实际签名裁剪
        return call("searchContent", key, quick, "1");
    }

    @Override
    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return call("searchContent", key, quick, pg);
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return call("playerContent", flag, id, vipFlags);
    }

    @Override
    public String liveContent(String url) throws Exception {
        return PyProxyAddress.normalize(call("liveContent", url), scriptProxyBase, proxyToken, scriptSiteKey);
    }

    @Override
    public String action(String action) throws Exception {
        return call("action", action);
    }

    @Override
    public boolean manualVideoCheck() {
        return false;
    }

    @Override
    public boolean isVideoFormat(String url) {
        return false;
    }

    /** Pins the exact child until its subscription closes; no event can reacquire a replacement. */
    public PyRuntime.DanmakuSession openDanmaku(String id, PyRuntime.DanmakuListener listener) {
        inFlight.incrementAndGet();
        boolean retained = false;
        try {
            PyRuntime rt = acquire();
            synchronized (startupLifecycle) {
                if (destroyed) throw new IllegalStateException("script instance is no longer active");
                PyProcessPool.touch(this);
            }
            PyRuntime.DanmakuSession session = rt.openDanmaku(id, listener, inFlight::decrementAndGet);
            retained = true;
            return session;
        } finally {
            if (!retained) inFlight.decrementAndGet();
        }
    }

    public PyProxyResponse callProxy(java.util.Map<String, String> params) throws Exception {
        inFlight.incrementAndGet();
        boolean retained = false;
        try {
            PyRuntime rt = acquire();
            synchronized (startupLifecycle) {
                if (destroyed) throw new IllegalStateException("script instance is no longer active");
                PyProcessPool.touch(this);
            }
            String result = rt.callJson("proxy", java.util.Collections.singletonList(params));
            PyProxyResponse response;
            try {
                response = PyProxyResponse.decode(result, rt, inFlight::decrementAndGet);
            } catch (RuntimeException malformed) {
                rt.close();
                throw malformed;
            }
            retained = response.contentLength < 0;
            return response;
        } finally {
            if (!retained) inFlight.decrementAndGet();
        }
    }

    @Override
    public Object[] proxy(java.util.Map<String, String> params) {
        try {
            PyProxyResponse response = callProxy(params);
            return new Object[] { response.status, response.mime, response.body, response.headers };
        } catch (Exception error) {
            throw new IllegalStateException("script proxy failed");
        }
    }

    public String api() {
        return api;
    }
}
