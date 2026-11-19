package com.fongmi.companion;

import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.HostAccess;
import org.graalvm.polyglot.Source;
import org.graalvm.polyglot.Value;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * XPTV / NowShowTime 脚本站（{@code type:3, api:csp_xxx, ext:<脚本 .js 地址>}）。
 *
 * <p>XPTV 契约：{@code getConfig / getCards / getTracks / getPlayinfo / search}，参数与返回都是 JSON 字符串。
 * NowShowTime v1 契约：{@code getCategories / getVideosByCategory / getVideoDetail / getPlayUrl / search}，
 * 以 CommonJS 导出、返回对象。两者都映射成 TVBox spider 的 home / category / detail / player / search。
 *
 * <p>宿主环境（$fetch、cheerio、CryptoJS、JSEncrypt…）由 {@code xptv/xptv-runtime.js} + {@link XptvHost} 提供。
 * GraalJS 上下文不是线程安全的，所有入口串行执行。
 */
public final class XptvSpider extends com.github.catvod.crawler.Spider {
    private static final String RES_CRYPTO = "/xptv/crypto-js-4.2.0.min.js";
    private static final String RES_RUNTIME = "/xptv/xptv-runtime.js";
    private static final String PREFIX_XPTV = "xptv:";
    private static final String PREFIX_NST = "nst:";
    private static final String PREFIX_VOD = "xv:";
    private static final Pattern IDENT = Pattern.compile("[A-Za-z_$][\\w$]*");
    private static final Pattern DRPY = Pattern.compile("(?m)^\\s*(var|let|const)\\s+rule\\s*=");
    private static final int MAX_TICKS = 2000;

    private static final String PRELUDE = """
            globalThis.crypto = {
              getRandomValues: function (arr) { for (var i = 0; i < arr.length; i++) arr[i] = __xptv.randomInt() >>> 0; return arr; }
            };
            """;
    private static final String INVOKER = """
            globalThis.__xptvInvoke = function (fn, argsJson) {
              var box = { done: false };
              var args = JSON.parse(argsJson);
              Promise.resolve().then(function () { return fn.apply(null, args); }).then(function (v) {
                if (typeof v === 'string') { box.kind = 's'; box.value = v; }
                else { box.kind = 'j'; box.value = v === undefined ? 'null' : JSON.stringify(v); }
                box.done = true;
              }, function (e) {
                box.error = String((e && (e.stack || e.message)) || e);
                box.done = true;
              });
              return box;
            };
            globalThis.__xptvGlobalJson = function (name) {
              try {
                var v = (0, eval)('typeof ' + name + " === 'undefined' ? undefined : " + name);
                return v == null || typeof v !== 'object' ? null : JSON.stringify(v);
              } catch (e) { return null; }
            };
            """;

    private static final Map<String, String> SCRIPT_CACHE = new ConcurrentHashMap<>();

    private enum Mode { XPTV, NST }

    private final String url;
    private final Context context;
    private final Mode mode;
    /** NST 分类 id 可能是数字，回调时要按原类型传回脚本。 */
    private final Map<String, Object> nstCategories = new HashMap<>();
    private Map<String, Object> nstSort;
    /** 每个分类上一页的 id 签名：部分站翻过末页仍返回最后一页，据此停止翻页。 */
    private final Map<String, String[]> lastPage = new HashMap<>();

    public XptvSpider(String url, String script) {
        this.url = url == null ? "" : url;
        this.context = Context.newBuilder("js")
                .allowAllAccess(true)
                .allowHostAccess(HostAccess.ALL)
                .option("engine.WarnInterpreterOnly", "false")
                .build();
        try {
            context.getBindings("js").putMember("__xptv", new XptvHost(tagOf(this.url)));
            context.eval("js", PRELUDE);
            // crypto-js 必须在 module/exports 定义之前加载，否则 UMD 走 CommonJS 分支不挂 globalThis.CryptoJS
            context.eval(Source.newBuilder("js", resource(RES_CRYPTO), "crypto-js.js").buildLiteral());
            context.eval(Source.newBuilder("js", resource(RES_RUNTIME), "xptv-runtime.js").buildLiteral());
            context.eval("js", INVOKER);
            context.eval(Source.newBuilder("js", script == null ? "" : script, scriptName(this.url)).buildLiteral());
            if (has("getConfig") && has("getCards") && has("getTracks")) {
                mode = Mode.XPTV;
            } else if (has("getCategories") && has("getVideosByCategory") && has("getVideoDetail")) {
                mode = Mode.NST;
            } else {
                throw new IllegalArgumentException("not an XPTV/NowShowTime script: " + this.url);
            }
        } catch (RuntimeException | Error e) {
            context.close();
            throw e;
        }
    }

    // ---- 识别与加载 ----

    /** 脚本正文是否符合 XPTV 或 NowShowTime 契约（drpy rule 脚本排除）。 */
    public static boolean isSupportedScript(String script) {
        if (script == null || script.isBlank()) return false;
        if (DRPY.matcher(script).find()) return false;
        boolean xptv = script.contains("getCards") && script.contains("getTracks") && script.contains("getConfig");
        boolean nst = script.contains("getVideosByCategory") && script.contains("getVideoDetail");
        return xptv || nst;
    }

    /** ext 是否是一个 http(s) 的 .js 脚本地址（允许查询串）。 */
    public static boolean isScriptUrl(String ext) {
        if (ext == null) return false;
        String value = ext.trim();
        String lower = value.toLowerCase(Locale.ROOT);
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false;
        if (value.contains("\"") || value.contains(" ")) return false;
        int cut = lower.length();
        int q = lower.indexOf('?');
        if (q >= 0) cut = q;
        int h = lower.indexOf('#');
        if (h >= 0 && h < cut) cut = h;
        return lower.substring(0, cut).endsWith(".js");
    }

    /**
     * 工厂入口：api 不是 .js（drpy2 等由别的路径处理）、ext 是脚本地址且脚本符合契约时创建，否则返回 null。
     */
    public static XptvSpider create(String api, String ext, File cacheDir) {
        if (!isScriptUrl(ext)) return null;
        if (api != null && api.toLowerCase(Locale.ROOT).contains(".js")) return null;
        String scriptUrl = ext.trim();
        String script = loadScript(scriptUrl, cacheDir);
        if (!isSupportedScript(script)) return null;
        return new XptvSpider(scriptUrl, script);
    }

    static String loadScript(String scriptUrl, File cacheDir) {
        String cached = SCRIPT_CACHE.get(scriptUrl);
        if (cached != null) return cached;
        File disk = cacheDir == null ? null : new File(new File(cacheDir, "xptv"), md5(scriptUrl) + ".js");
        String text = download(scriptUrl);
        if (!isSupportedScript(text)) {
            // raw.githubusercontent 在国内经常不通，同一文件走 jsDelivr 镜像再试一次
            String mirror = jsDelivrMirror(scriptUrl);
            if (mirror != null) {
                String mirrored = download(mirror);
                if (isSupportedScript(mirrored)) text = mirrored;
            }
        }
        if (text != null && isSupportedScript(text)) {
            if (disk != null) {
                try {
                    Files.createDirectories(disk.getParentFile().toPath());
                    Files.writeString(disk.toPath(), text, StandardCharsets.UTF_8);
                } catch (IOException ignored) {
                    // 磁盘缓存只是离线兜底
                }
            }
        } else if (disk != null && disk.isFile()) {
            try {
                text = Files.readString(disk.toPath(), StandardCharsets.UTF_8);
            } catch (IOException ignored) {
                // 保留下载结果（可能为 null）
            }
        }
        if (text != null) SCRIPT_CACHE.put(scriptUrl, text);
        return text;
    }

    private static String download(String target) {
        try {
            Map<String, Object> res = JsonCodec.parseObject(
                    new XptvHost("loader").fetch("GET", target, null, "{\"timeout\":20000}"));
            Object status = res.get("status");
            Object data = res.get("data");
            if (status instanceof Number n && n.intValue() / 100 == 2 && data != null && !String.valueOf(data).isBlank()) {
                return String.valueOf(data);
            }
            System.err.println("[XptvSpider] 下载脚本失败 " + target + " status=" + status + " " + res.get("error"));
        } catch (RuntimeException e) {
            System.err.println("[XptvSpider] 下载脚本失败 " + target + " " + e);
        }
        return null;
    }

    private static final Pattern RAW_GITHUB = Pattern.compile(
            "^https://raw\\.githubusercontent\\.com/([^/]+)/([^/]+)/(?:refs/heads/)?([^/]+)/(.+)$");

    /** raw.githubusercontent.com/u/r/[refs/heads/]branch/path → cdn.jsdelivr.net/gh/u/r@branch/path */
    static String jsDelivrMirror(String url) {
        java.util.regex.Matcher m = RAW_GITHUB.matcher(url == null ? "" : url.trim());
        if (!m.matches()) return null;
        return "https://cdn.jsdelivr.net/gh/" + m.group(1) + "/" + m.group(2) + "@" + m.group(3) + "/" + m.group(4);
    }

    // ---- Spider ----

    @Override
    public void init(android.content.Context context, String extend) {}

    @Override
    public synchronized String homeContent(boolean filter) {
        return mode == Mode.XPTV ? xptvHome() : nstHome();
    }

    @Override
    public synchronized String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        int page = page(pg);
        List<Map<String, Object>> list = mode == Mode.XPTV ? xptvCards(tid, page, extend) : nstCards(tid, page, extend);
        boolean repeat = repeatsPrevious(tid, page, list);
        if (repeat) list = List.of();
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("page", page);
        result.put("pagecount", list.isEmpty() ? page : page + 1);
        result.put("limit", list.size());
        result.put("total", list.isEmpty() ? (page - 1) * 20 : (page + 1) * Math.max(list.size(), 1));
        result.put("list", list);
        return JsonCodec.stringify(result);
    }

    @Override
    public synchronized String detailContent(List<String> ids) {
        String id = ids == null || ids.isEmpty() ? "" : ids.get(0);
        Map<String, Object> vodRef = decodeMap(id, PREFIX_VOD);
        Map<String, Object> vod = new LinkedHashMap<>();
        vod.put("vod_id", id);
        vod.put("vod_name", str(vodRef.get("name")));
        vod.put("vod_pic", str(vodRef.get("pic")));
        vod.put("vod_remarks", str(vodRef.get("remarks")));
        if (mode == Mode.XPTV) xptvTracks(vodRef, vod);
        else nstTracks(vodRef, vod);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("list", List.of(vod));
        return JsonCodec.stringify(result);
    }

    @Override
    public synchronized String playerContent(String flag, String id, List<String> vipFlags) {
        String playUrl = id == null ? "" : id;
        Map<String, Object> header = new LinkedHashMap<>();
        if (playUrl.startsWith(PREFIX_XPTV)) {
            Object ext = JsonCodec.parse(decode(playUrl.substring(PREFIX_XPTV.length())));
            Map<String, Object> info = asMap(invokeJson("getPlayinfo", jsonArg(ext)));
            List<Object> urls = asList(info.get("urls"));
            playUrl = urls.isEmpty() ? "" : str(urls.get(0));
            List<Object> headers = asList(info.get("headers"));
            if (!headers.isEmpty()) copyHeaders(headers.get(0), header);
        } else if (playUrl.startsWith(PREFIX_NST)) {
            Object res = invoke("getPlayUrl", decode(playUrl.substring(PREFIX_NST.length())));
            if (res instanceof Map<?, ?> map) {
                playUrl = str(map.get("url"));
                copyHeaders(map.get("headers"), header);
            } else {
                playUrl = str(res);
            }
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("parse", 0);
        result.put("jx", 0);
        result.put("url", playUrl);
        if (!header.isEmpty()) result.put("header", header);
        return JsonCodec.stringify(result);
    }

    @Override
    public synchronized String searchContent(String key, boolean quick, String pg) {
        int page = page(pg);
        List<Map<String, Object>> list = new ArrayList<>();
        if (mode == Mode.XPTV) {
            String fn = has("_showtimeSearch") ? "_showtimeSearch" : "search";
            Map<String, Object> args = new LinkedHashMap<>();
            args.put("text", key == null ? "" : key);
            args.put("wd", key == null ? "" : key);
            args.put("page", page);
            Map<String, Object> res = asMap(invokeJson(fn, JsonCodec.stringify(args)));
            for (Object card : asList(res.get("list"))) list.add(xptvVod(card));
        } else if (page == 1 && has("search")) {
            for (Object item : asList(invoke("search", key == null ? "" : key))) list.add(nstVod(item));
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("page", page);
        result.put("pagecount", list.isEmpty() || mode == Mode.NST ? page : page + 1);
        result.put("list", list);
        return JsonCodec.stringify(result);
    }

    @Override
    public synchronized void destroy() {
        context.close();
    }

    // ---- XPTV ----

    private String xptvHome() {
        Map<String, Object> config = asMap(invokeJson("getConfig"));
        List<Map<String, Object>> classes = new ArrayList<>();
        Map<String, Object> filters = new LinkedHashMap<>();
        Map<String, Object> filterList = globalMap("filterList");
        if (filterList.isEmpty()) filterList = globalMap("filterObj");
        for (Object tabValue : asList(config.get("tabs"))) {
            Map<String, Object> tab = asMap(tabValue);
            Object ext = tab.get("ext");
            String typeId = ext instanceof String s ? s : JsonCodec.stringify(ext == null ? Map.of() : ext);
            Map<String, Object> cls = new LinkedHashMap<>();
            cls.put("type_id", typeId);
            cls.put("type_name", str(tab.get("name")));
            classes.add(cls);
            Object extId = asMap(ext instanceof String s ? safeParse(s) : ext).get("id");
            Object filter = extId == null ? null : filterList.get(String.valueOf(extId));
            if (filter instanceof List<?> l && !l.isEmpty()) filters.put(typeId, filter);
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("class", classes);
        if (!filters.isEmpty()) result.put("filters", filters);
        result.put("list", List.of());
        return JsonCodec.stringify(result);
    }

    private List<Map<String, Object>> xptvCards(String tid, int page, Map<String, String> extend) {
        Map<String, Object> ext = new LinkedHashMap<>(asMap(safeParse(tid)));
        if (ext.isEmpty() && tid != null) ext.put("id", tid);
        ext.put("page", page);
        ext.put("filters", extend == null ? Map.of() : new LinkedHashMap<>(extend));
        Map<String, Object> res = asMap(invokeJson("getCards", JsonCodec.stringify(ext)));
        List<Map<String, Object>> list = new ArrayList<>();
        for (Object card : asList(res.get("list"))) list.add(xptvVod(card));
        return list;
    }

    private Map<String, Object> xptvVod(Object cardValue) {
        Map<String, Object> card = asMap(cardValue);
        Map<String, Object> ref = new LinkedHashMap<>();
        ref.put("ext", card.get("ext") == null ? Map.of("url", str(card.get("vod_id"))) : card.get("ext"));
        ref.put("name", str(card.get("vod_name")));
        ref.put("pic", str(card.get("vod_pic")));
        ref.put("remarks", str(card.get("vod_remarks")));
        Map<String, Object> vod = new LinkedHashMap<>();
        vod.put("vod_id", PREFIX_VOD + encode(JsonCodec.stringify(ref)));
        vod.put("vod_name", ref.get("name"));
        vod.put("vod_pic", ref.get("pic"));
        vod.put("vod_remarks", ref.get("remarks"));
        return vod;
    }

    private void xptvTracks(Map<String, Object> ref, Map<String, Object> vod) {
        Map<String, Object> res = asMap(invokeJson("getTracks", jsonArg(ref.get("ext"))));
        List<String> froms = new ArrayList<>();
        List<String> urls = new ArrayList<>();
        int n = 0;
        for (Object groupValue : asList(res.get("list"))) {
            n++;
            Map<String, Object> group = asMap(groupValue);
            List<String> episodes = new ArrayList<>();
            int e = 0;
            for (Object trackValue : asList(group.get("tracks"))) {
                e++;
                Map<String, Object> track = asMap(trackValue);
                Object ext = track.get("ext");
                String pan = str(track.get("pan"));
                String playId;
                if ((ext == null || asMap(ext).isEmpty() && !(ext instanceof String)) && !pan.isEmpty()) {
                    playId = pan;
                } else {
                    playId = PREFIX_XPTV + encode(JsonCodec.stringify(ext == null ? Map.of() : ext));
                }
                String name = clean(str(track.get("name")));
                episodes.add((name.isEmpty() ? "第" + e + "集" : name) + "$" + playId);
            }
            if (episodes.isEmpty()) continue;
            String from = clean(str(group.get("title")));
            froms.add(uniqueFrom(froms, from.isEmpty() ? "线路" + n : from));
            urls.add(String.join("#", episodes));
        }
        vod.put("vod_play_from", String.join("$$$", froms));
        vod.put("vod_play_url", String.join("$$$", urls));
    }

    // ---- NowShowTime ----

    private String nstHome() {
        List<Map<String, Object>> classes = new ArrayList<>();
        nstCategories.clear();
        for (Object catValue : asList(invoke("getCategories"))) {
            Map<String, Object> cat = asMap(catValue);
            Object rawId = cat.get("id");
            String typeId = str(rawId);
            nstCategories.put(typeId, rawId);
            Map<String, Object> cls = new LinkedHashMap<>();
            cls.put("type_id", typeId);
            cls.put("type_name", str(cat.get("name")));
            classes.add(cls);
        }
        Map<String, Object> filters = new LinkedHashMap<>();
        if (has("getSortOptions")) {
            Object sort = invoke("getSortOptions");
            Map<String, Object> option = sort instanceof List<?> l && !l.isEmpty() ? asMap(l.get(0)) : asMap(sort);
            if (!option.isEmpty() && option.get("value") instanceof List<?>) {
                nstSort = option;
                for (Map<String, Object> cls : classes) filters.put(str(cls.get("type_id")), List.of(option));
            }
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("class", classes);
        if (!filters.isEmpty()) result.put("filters", filters);
        result.put("list", List.of());
        return JsonCodec.stringify(result);
    }

    private List<Map<String, Object>> nstCards(String tid, int page, Map<String, String> extend) {
        Object categoryId = nstCategories.getOrDefault(tid, tid);
        Object sort = null;
        if (nstSort != null) {
            String key = str(nstSort.get("key"));
            sort = extend != null && extend.containsKey(key) ? extend.get(key) : nstSort.get("init");
        }
        List<Map<String, Object>> list = new ArrayList<>();
        for (Object item : asList(invoke("getVideosByCategory", categoryId, page, sort))) list.add(nstVod(item));
        return list;
    }

    private Map<String, Object> nstVod(Object itemValue) {
        Map<String, Object> item = asMap(itemValue);
        Map<String, Object> ref = new LinkedHashMap<>();
        ref.put("id", item.get("id") == null ? item.get("url") : item.get("id"));
        ref.put("name", str(item.get("title")));
        ref.put("pic", str(item.get("cover")));
        ref.put("remarks", str(item.get("description")));
        Map<String, Object> vod = new LinkedHashMap<>();
        vod.put("vod_id", PREFIX_VOD + encode(JsonCodec.stringify(ref)));
        vod.put("vod_name", ref.get("name"));
        vod.put("vod_pic", ref.get("pic"));
        vod.put("vod_remarks", ref.get("remarks"));
        return vod;
    }

    private void nstTracks(Map<String, Object> ref, Map<String, Object> vod) {
        Map<String, Object> detail = asMap(invoke("getVideoDetail", ref.get("id")));
        if (str(vod.get("vod_name")).isEmpty()) vod.put("vod_name", str(detail.get("title")));
        if (detail.get("description") != null) vod.put("vod_content", str(detail.get("description")));
        List<String> episodes = new ArrayList<>();
        int e = 0;
        for (Object resValue : asList(detail.get("resolutions"))) {
            e++;
            Map<String, Object> res = asMap(resValue);
            String name = clean(str(res.get("name")));
            episodes.add((name.isEmpty() ? "第" + e + "集" : name) + "$" + PREFIX_NST + encode(str(res.get("url"))));
        }
        vod.put("vod_play_from", episodes.isEmpty() ? "" : "播放");
        vod.put("vod_play_url", String.join("#", episodes));
    }

    // ---- JS 调用 ----

    private boolean has(String name) {
        return lookup(name) != null;
    }

    private Value lookup(String name) {
        if (!IDENT.matcher(name).matches()) throw new IllegalArgumentException("bad function name " + name);
        Value value = context.eval("js", "(typeof " + name + " === 'function') ? " + name
                + " : ((typeof module === 'object' && module && module.exports && typeof module.exports['" + name
                + "'] === 'function') ? module.exports['" + name + "'] : null)");
        return value == null || value.isNull() ? null : value;
    }

    /** 调用脚本函数并等 Promise 落定：字符串原样返回，其余为 JSON 解析后的 Map/List/标量。 */
    private Object invoke(String name, Object... args) {
        Value fn = lookup(name);
        if (fn == null) throw new IllegalStateException("script has no function " + name);
        Value box = context.getBindings("js").getMember("__xptvInvoke")
                .execute(fn, JsonCodec.stringify(new ArrayList<>(Arrays.asList(args))));
        for (int i = 0; i < MAX_TICKS && !box.getMember("done").asBoolean(); i++) {
            // 每次顶层 eval 结束都会清空微任务队列，推进脚本里的 await 链
            context.eval("js", "void 0");
        }
        if (!box.getMember("done").asBoolean()) throw new IllegalStateException(name + " did not settle");
        Value error = box.getMember("error");
        if (error != null && !error.isNull()) throw new RuntimeException(name + ": " + error.asString());
        String value = box.getMember("value").asString();
        return "s".equals(box.getMember("kind").asString()) ? value : JsonCodec.parse(value);
    }

    /** XPTV 函数返回 jsonify 字符串，这里解析成对象。 */
    private Object invokeJson(String name, Object... args) {
        Object res = invoke(name, args);
        return res instanceof String s ? safeParse(s) : res;
    }

    private Map<String, Object> globalMap(String name) {
        Value json = context.getBindings("js").getMember("__xptvGlobalJson").execute(name);
        return json == null || json.isNull() ? Map.of() : asMap(safeParse(json.asString()));
    }

    // ---- 工具 ----

    private boolean repeatsPrevious(String tid, int page, List<Map<String, Object>> list) {
        StringBuilder sig = new StringBuilder();
        for (Map<String, Object> vod : list) sig.append(vod.get("vod_id")).append('\n');
        String key = tid == null ? "" : tid;
        String[] prev = lastPage.get(key);
        lastPage.put(key, new String[]{String.valueOf(page), sig.toString()});
        return page > 1 && !list.isEmpty() && prev != null
                && String.valueOf(page - 1).equals(prev[0]) && sig.toString().equals(prev[1]);
    }

    private static String jsonArg(Object ext) {
        if (ext instanceof String s) return s;
        return JsonCodec.stringify(ext == null ? Map.of() : ext);
    }

    @SuppressWarnings("unchecked")
    private static void copyHeaders(Object value, Map<String, Object> out) {
        if (!(value instanceof Map<?, ?> map)) return;
        for (Map.Entry<?, ?> e : ((Map<Object, Object>) map).entrySet()) {
            if (e.getKey() != null && e.getValue() != null) out.put(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
        }
    }

    private static String uniqueFrom(List<String> existing, String from) {
        String candidate = from;
        for (int i = 2; existing.contains(candidate); i++) candidate = from + i;
        return candidate;
    }

    /** {@code $ # 换行} 会破坏 vod_play_url 结构。 */
    private static String clean(String value) {
        return value.replace('$', '＄').replace('#', '＃').replaceAll("[\\r\\n]+", " ").trim();
    }

    private static int page(String pg) {
        try {
            return Math.max(1, Integer.parseInt(pg == null ? "1" : pg.trim()));
        } catch (NumberFormatException e) {
            return 1;
        }
    }

    private static Object safeParse(String text) {
        if (text == null) return null;
        String t = text.trim();
        if (!t.startsWith("{") && !t.startsWith("[")) return text;
        try {
            return JsonCodec.parse(t);
        } catch (RuntimeException e) {
            return text;
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<?, ?> m ? (Map<String, Object>) m : Map.of();
    }

    @SuppressWarnings("unchecked")
    private static List<Object> asList(Object value) {
        return value instanceof List<?> l ? (List<Object>) l : List.of();
    }

    private static String str(Object value) {
        if (value == null) return "";
        if (value instanceof Double d && d == Math.rint(d) && !d.isInfinite()) return String.valueOf(d.longValue());
        return String.valueOf(value);
    }

    private static Map<String, Object> decodeMap(String id, String prefix) {
        if (id == null || !id.startsWith(prefix)) return Map.of("ext", Map.of("url", id == null ? "" : id),
                "id", id == null ? "" : id);
        return asMap(safeParse(decode(id.substring(prefix.length()))));
    }

    private static String encode(String text) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(text.getBytes(StandardCharsets.UTF_8));
    }

    private static String decode(String text) {
        return new String(Base64.getUrlDecoder().decode(text), StandardCharsets.UTF_8);
    }

    private static String resource(String path) {
        try (InputStream in = XptvSpider.class.getResourceAsStream(path)) {
            if (in == null) throw new IllegalStateException("missing resource " + path);
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("cannot read " + path, e);
        }
    }

    private static String tagOf(String url) {
        String name = scriptName(url);
        return name.endsWith(".js") ? name.substring(0, name.length() - 3) : name;
    }

    private static String scriptName(String url) {
        String path = url;
        int q = path.indexOf('?');
        if (q >= 0) path = path.substring(0, q);
        int slash = path.lastIndexOf('/');
        String name = slash >= 0 ? path.substring(slash + 1) : path;
        return name.isEmpty() ? "xptv.js" : name;
    }

    private static String md5(String text) {
        try {
            byte[] d = MessageDigest.getInstance("MD5").digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(text.hashCode());
        }
    }
}
