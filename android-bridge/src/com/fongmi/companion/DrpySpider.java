package com.fongmi.companion;

import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.HostAccess;
import org.graalvm.polyglot.Source;
import org.graalvm.polyglot.Value;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * drpy2 引擎站（{@code type:3, api:<…/drpy2.min.js>, ext:<规则 .js 地址或规则正文>}）。
 *
 * <p>drpy2 是一个 ES 模块：{@code export default {init, home, homeVod, category, detail, play, search, …}}，
 * 依赖宿主的 {@code req / pdfh / pdfa / pd / pdfl / joinUrl / local}（{@link DrpyHost}）。
 *
 * <p>模块图在 Java 侧先整体下载（原地址 → jsDelivr 镜像 → 磁盘缓存），把每个 import 说明符改写成
 * 本地平铺目录里的相对文件名，再交给 GraalJS 按 ES 模块求值：
 * <ul>
 *   <li>{@code assets://js/lib/crypto-js.js} → 内置垫片，导出已加载的 crypto-js 4.2.0（MIT，随包）。</li>
 *   <li>其余 {@code assets://js/lib/*} → 运行时从 jsDelivr 取 hjdhnx/dr_py 的 libs（LGPL，不随包分发）。</li>
 * </ul>
 * GraalJS 上下文不是线程安全的，所有入口串行执行。
 */
public final class DrpySpider extends com.github.catvod.crawler.Spider {
    private static final String RES_CRYPTO = "/xptv/crypto-js-4.2.0.min.js";
    private static final String ASSETS_PREFIX = "assets://js/lib/";
    private static final String ASSETS_MIRROR = "https://cdn.jsdelivr.net/gh/hjdhnx/dr_py@main/libs/";
    private static final String CRYPTO_SHIM_NAME = "__crypto-js.js";
    private static final String CRYPTO_SHIM = "export default globalThis.CryptoJS;\n";
    private static final Pattern API = Pattern.compile("(?i)(^|/)drpy2\\d?(\\.min)?\\.js$");
    /** 静态 import / export-from 的说明符（不含动态 import()）。 */
    private static final Pattern IMPORT = Pattern.compile(
            "(?:(?<=^)|(?<=[;\\s}]))(?:import|export)\\s*(?:[^'\"`;()]*?\\s*from\\s*)?([\"'])([^\"'\\r\\n]+)\\1");
    private static final int MAX_MODULES = 40;
    private static final int MAX_TICKS = 2000;

    private static final String PRELUDE = """
            (function () {
              var H = __drpy;
              function s(v) { return v == null ? '' : String(v); }
              globalThis.req = function (url, obj) {
                var r = JSON.parse(H.req(s(url), JSON.stringify(obj || {})));
                return r;
              };
              globalThis.pdfh = function (html, rule) { return H.pdfh(s(html), s(rule)); };
              globalThis.pd = function (html, rule, base) { return H.pd(s(html), s(rule), s(base)); };
              globalThis.pdfa = function (html, rule) { return JSON.parse(H.pdfa(s(html), s(rule))); };
              globalThis.pdfl = function (html, rule, text, url, key) {
                return JSON.parse(H.pdfl(s(html), s(rule), s(text), s(url), s(key)));
              };
              globalThis.joinUrl = function (parent, child) { return H.joinUrl(s(parent), s(child)); };
              globalThis.local = {
                get: function (r, k) { return H.localGet(s(r), s(k)); },
                set: function (r, k, v) { H.localSet(s(r), s(k), typeof v === 'string' ? v : JSON.stringify(v)); },
                delete: function (r, k) { H.localDelete(s(r), s(k)); }
              };
              // drpy2 在模块（严格模式）里直接给 fetch / print 赋值，必须先有同名全局
              if (typeof globalThis.fetch === 'undefined') globalThis.fetch = function () { return ''; };
              if (typeof globalThis.print === 'undefined') globalThis.print = function () {};
              if (typeof globalThis.atob !== 'function') globalThis.atob = function (t) { return H.atob(s(t)); };
              if (typeof globalThis.btoa !== 'function') globalThis.btoa = function (t) { return H.btoa(s(t)); };
              function line(args) {
                var out = [];
                for (var i = 0; i < args.length; i++) {
                  var a = args[i];
                  out.push(typeof a === 'string' ? a : (function () { try { return JSON.stringify(a); } catch (e) { return String(a); } })());
                }
                var text = out.join(' ');
                return text.length > 600 ? text.substring(0, 600) + '…' : text;
              }
              globalThis.console = {
                log: function () { H.log(line(arguments)); },
                info: function () { H.log(line(arguments)); },
                warn: function () { H.log(line(arguments)); },
                error: function () { H.log(line(arguments)); },
                debug: function () {}
              };
              globalThis.__drpyInvoke = function (fn, argsJson) {
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
            })();
            """;

    private final String api;
    private final Context context;
    private final Value module;

    private DrpySpider(String api, File entry, File cacheDir) {
        this.api = api;
        this.context = Context.newBuilder("js")
                .allowAllAccess(true)
                .allowHostAccess(HostAccess.ALL)
                .option("engine.WarnInterpreterOnly", "false")
                .option("js.esm-eval-returns-exports", "true")
                .build();
        try {
            context.getBindings("js").putMember("__drpy", new DrpyHost(tagOf(api), cacheDir));
            context.eval(Source.newBuilder("js", resource(RES_CRYPTO), "crypto-js.js").buildLiteral());
            context.eval("js", PRELUDE);
            Value ns = context.eval(Source.newBuilder("js", entry).mimeType("application/javascript+module").build());
            Value def = ns == null ? null : ns.getMember("default");
            if (def == null || def.isNull() || !def.hasMember("init")) {
                throw new IllegalStateException("drpy2 module has no default export: " + api);
            }
            this.module = def;
        } catch (IOException e) {
            context.close();
            throw new IllegalStateException("cannot load drpy2 module " + api + ": " + e.getMessage(), e);
        } catch (RuntimeException | Error e) {
            context.close();
            throw e;
        }
    }

    // ---- 识别与加载 ----

    /** api 是否指向 drpy2 引擎（{@code drpy2.js / drpy2.min.js}，允许查询串）。 */
    public static boolean isDrpyApi(String api) {
        if (api == null) return false;
        String value = api.trim();
        int q = value.indexOf('?');
        if (q >= 0) value = value.substring(0, q);
        int h = value.indexOf('#');
        if (h >= 0) value = value.substring(0, h);
        return value.contains("/") && API.matcher(value).find();
    }

    /** 工厂入口：api 不是 drpy2 时返回 null；模块图下载失败时抛出，错误随调用返回。 */
    public static DrpySpider create(String api, String ext, File cacheDir) {
        if (!isDrpyApi(api)) return null;
        String url = api.trim();
        File base = cacheDir == null ? tempRoot() : cacheDir;
        File dir = new File(new File(base, "drpy"), md5(url).substring(0, 12));
        File entry = new ModuleGraph(dir).load(url);
        return new DrpySpider(url, entry, cacheDir);
    }

    private static File tempRoot() {
        try {
            return Files.createTempDirectory("drpy").toFile();
        } catch (IOException e) {
            throw new IllegalStateException("no cache dir for drpy", e);
        }
    }

    /** 下载并改写整个模块图；返回入口模块的本地文件。 */
    static final class ModuleGraph {
        private final File dir;
        private final Map<String, String> localNames = new LinkedHashMap<>();

        ModuleGraph(File dir) {
            this.dir = dir;
        }

        File load(String entryUrl) {
            try {
                Files.createDirectories(dir.toPath());
                Deque<String> queue = new ArrayDeque<>();
                queue.add(entryUrl);
                localNames.put(entryUrl, localName(entryUrl));
                while (!queue.isEmpty()) {
                    String url = queue.poll();
                    String text = fetch(url);
                    if (text == null) throw new IllegalStateException("drpy2 依赖下载失败: " + url);
                    StringBuilder out = new StringBuilder(text.length() + 64);
                    Matcher m = IMPORT.matcher(text);
                    int last = 0;
                    while (m.find()) {
                        String spec = m.group(2);
                        String target = resolve(url, spec);
                        if (target == null) continue;
                        String name = localNames.get(target);
                        if (name == null) {
                            if (localNames.size() >= MAX_MODULES) throw new IllegalStateException("drpy2 模块过多: " + url);
                            name = localName(target);
                            localNames.put(target, name);
                            if (!target.equals(CRYPTO_SHIM_NAME)) queue.add(target);
                        }
                        out.append(text, last, m.start(2)).append("./").append(name);
                        last = m.end(2);
                    }
                    out.append(text, last, text.length());
                    Files.writeString(new File(dir, localNames.get(url)).toPath(), out.toString(), StandardCharsets.UTF_8);
                }
                Files.writeString(new File(dir, CRYPTO_SHIM_NAME).toPath(), CRYPTO_SHIM, StandardCharsets.UTF_8);
                return new File(dir, localNames.get(entryUrl));
            } catch (IOException e) {
                throw new IllegalStateException("drpy2 缓存目录不可写: " + dir + " " + e.getMessage(), e);
            }
        }

        /** 说明符 → 下载地址；crypto-js 映射为内置垫片（返回其本地名）。 */
        private static String resolve(String from, String spec) {
            String s = spec.trim();
            if (s.startsWith(ASSETS_PREFIX)) {
                String file = s.substring(ASSETS_PREFIX.length());
                if (file.equalsIgnoreCase("crypto-js.js") || file.equalsIgnoreCase("crypto-js.min.js")) return CRYPTO_SHIM_NAME;
                return ASSETS_MIRROR + file;
            }
            String lower = s.toLowerCase(Locale.ROOT);
            if (lower.startsWith("http://") || lower.startsWith("https://")) return s;
            if (s.startsWith("./") || s.startsWith("../") || s.startsWith("/")) {
                try {
                    return URI.create(DrpyHost.asciiUrl(from)).resolve(DrpyHost.asciiUrl(s)).toString();
                } catch (IllegalArgumentException e) {
                    return null;
                }
            }
            return null;
        }

        private static String localName(String url) {
            if (url.equals(CRYPTO_SHIM_NAME)) return CRYPTO_SHIM_NAME;
            String path = url;
            int q = path.indexOf('?');
            if (q >= 0) path = path.substring(0, q);
            String file = path.substring(path.lastIndexOf('/') + 1);
            try {
                file = java.net.URLDecoder.decode(file.replace("+", "%2B"), StandardCharsets.UTF_8);
            } catch (IllegalArgumentException ignored) {
                // 保留原名
            }
            file = file.replaceAll("[\\\\/:*?\"<>|\\s]", "_");
            if (file.isEmpty()) file = "index.js";
            if (!file.endsWith(".js") && !file.endsWith(".mjs")) file = file + ".js";
            return md5(url).substring(0, 8) + "-" + file;
        }

        /** 原地址 → jsDelivr 镜像 → 磁盘原文缓存。 */
        private String fetch(String url) throws IOException {
            File raw = new File(new File(dir, "raw"), md5(url) + ".js");
            String text = download(url);
            if (text == null) {
                String mirror = XptvSpider.jsDelivrMirror(url);
                if (mirror != null) text = download(mirror);
            }
            if (text != null) {
                Files.createDirectories(raw.getParentFile().toPath());
                Files.writeString(raw.toPath(), text, StandardCharsets.UTF_8);
                return text;
            }
            return raw.isFile() ? Files.readString(raw.toPath(), StandardCharsets.UTF_8) : null;
        }

        private static String download(String url) {
            Map<String, Object> res = JsonCodec.parseObject(new DrpyHost("loader", null).req(url, "{\"timeout\":20000}"));
            Object code = res.get("code");
            Object content = res.get("content");
            if (code instanceof Number n && n.intValue() / 100 == 2 && content != null && !String.valueOf(content).isBlank()) {
                return String.valueOf(content);
            }
            System.err.println("[DrpySpider] 下载模块失败 " + url + " code=" + code);
            return null;
        }
    }

    // ---- Spider ----

    @Override
    public synchronized void init(android.content.Context ctx, String extend) {
        String ext = extend == null ? "" : extend.trim();
        Object arg = ext;
        if (ext.startsWith("{") && ext.endsWith("}")) {
            try {
                arg = JsonCodec.parse(ext);
            } catch (RuntimeException ignored) {
                // 不是 JSON，按规则正文传
            }
        }
        call("init", arg);
    }

    @Override
    public synchronized String homeContent(boolean filter) {
        Map<String, Object> home = new LinkedHashMap<>(asMap(parse(callString("home", filter))));
        Object list = home.get("list");
        if (!(list instanceof List<?> l) || l.isEmpty()) {
            try {
                Object vod = asMap(parse(callString("homeVod"))).get("list");
                if (vod instanceof List<?> v && !v.isEmpty()) home.put("list", vod);
            } catch (RuntimeException e) {
                System.err.println("[DrpySpider] homeVod 失败 " + e.getMessage());
            }
        }
        return JsonCodec.stringify(home);
    }

    @Override
    public synchronized String homeVideoContent() {
        return callString("homeVod");
    }

    @Override
    public synchronized String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        return callString("category", tid == null ? "" : tid, pg == null ? "1" : pg, filter,
                extend == null ? new LinkedHashMap<>() : new LinkedHashMap<>(extend));
    }

    @Override
    public synchronized String detailContent(List<String> ids) {
        return callString("detail", ids == null || ids.isEmpty() ? "" : ids.get(0));
    }

    @Override
    public synchronized String playerContent(String flag, String id, List<String> vipFlags) {
        return callString("play", flag == null ? "" : flag, id == null ? "" : id,
                vipFlags == null ? new ArrayList<>() : new ArrayList<>(vipFlags));
    }

    @Override
    public synchronized String searchContent(String key, boolean quick) {
        return searchContent(key, quick, "1");
    }

    @Override
    public synchronized String searchContent(String key, boolean quick, String pg) {
        return callString("search", key == null ? "" : key, quick, pg == null ? "1" : pg);
    }

    @Override
    public synchronized void destroy() {
        context.close();
    }

    // ---- JS 调用 ----

    private String callString(String name, Object... args) {
        Object res = call(name, args);
        if (res == null) return "";
        return res instanceof String s ? s : JsonCodec.stringify(res);
    }

    /** 调用 default 导出上的函数并等 Promise 落定：字符串原样返回，其余为 JSON 解析结果。 */
    private Object call(String name, Object... args) {
        Value fn = module.getMember(name);
        if (fn == null || !fn.canExecute()) throw new IllegalStateException("drpy2 has no function " + name);
        List<Object> list = new ArrayList<>(args.length);
        for (Object a : args) list.add(a);
        Value box = context.getBindings("js").getMember("__drpyInvoke").execute(fn, JsonCodec.stringify(list));
        for (int i = 0; i < MAX_TICKS && !box.getMember("done").asBoolean(); i++) {
            context.eval("js", "void 0");
        }
        if (!box.getMember("done").asBoolean()) throw new IllegalStateException(name + " did not settle");
        Value error = box.getMember("error");
        if (error != null && !error.isNull()) throw new RuntimeException(name + ": " + error.asString());
        String value = box.getMember("value").asString();
        return "s".equals(box.getMember("kind").asString()) ? value : JsonCodec.parse(value);
    }

    // ---- 工具 ----

    private static Object parse(String text) {
        if (text == null) return null;
        String t = text.trim();
        if (!t.startsWith("{") && !t.startsWith("[")) return null;
        try {
            return JsonCodec.parse(t);
        } catch (RuntimeException e) {
            return null;
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<?, ?> m ? (Map<String, Object>) m : Map.of();
    }

    private static String resource(String path) {
        try (InputStream in = DrpySpider.class.getResourceAsStream(path)) {
            if (in == null) throw new IllegalStateException("missing resource " + path);
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("cannot read " + path, e);
        }
    }

    private static String tagOf(String api) {
        String path = api;
        int q = path.indexOf('?');
        if (q >= 0) path = path.substring(0, q);
        String name = path.substring(path.lastIndexOf('/') + 1);
        return name.isEmpty() ? "drpy2" : name;
    }

    static String md5(String text) {
        try {
            byte[] d = MessageDigest.getInstance("MD5").digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            return String.format("%032x", text.hashCode() & 0xffffffffL);
        }
    }
}
