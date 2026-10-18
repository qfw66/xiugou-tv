package com.fongmi.companion;

import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.HostAccess;
import org.graalvm.polyglot.Value;
import org.graalvm.polyglot.proxy.ProxyExecutable;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Executes extra.js source adapters in the companion JVM. */
public final class JavaScriptSpider extends com.github.catvod.crawler.Spider {
    private static final String BOOTSTRAP = """
            const __node = (json) => {
              const n = typeof json === 'string' ? JSON.parse(json) : json;
              return {
                raw: n,
                text: () => n.text || '',
                html: () => n.html || '',
                outerHtml: () => n.outerHtml || '',
                attr: (name) => (n.attrs && n.attrs[name]) || '',
                find: (selector) => __collection(JSON.parse(__htmlFind(JSON.stringify(n), selector))),
              };
            };
            const __collection = (items) => {
              const values = (items || []).map((item) => __node(item));
              const collection = {
                length: values.length,
                get: (index) => index === undefined ? values : values[index],
                toArray: () => values,
                eq: (index) => __collection(index >= 0 && index < values.length ? [values[index].raw] : []),
                first: () => __collection(values.length ? [values[0].raw] : []),
                last: () => __collection(values.length ? [values[values.length - 1].raw] : []),
                text: () => values.map((value) => value.text()).join(''),
                html: () => values.length ? values[0].html() : '',
                attr: (name) => values.length ? values[0].attr(name) : '',
                find: (selector) => __collection(values.flatMap((value) => JSON.parse(__htmlFind(JSON.stringify(value.raw), selector)))),
                each: function(fn) { values.forEach((value, index) => fn(index, value)); return collection; },
                map: function(fn) { return __collection(values.map((value, index) => fn(index, value)).filter(Boolean)); },
              };
              return collection;
            };
            const __kittyLoad = (html) => {
              const source = html == null ? '' : String(html);
              const $ = (selectorOrNode) => {
                if (typeof selectorOrNode === 'string') return __collection(JSON.parse(__htmlSelect(source, selectorOrNode)));
                if (selectorOrNode && selectorOrNode.raw) return __collection([selectorOrNode.raw]);
                return __collection([]);
              };
              $.root = () => $(source);
              $.html = () => source;
              return $;
            };
            const __makeEnv = (value) => {
              const env = Object.assign({}, value || {});
              env.baseUrl = env.baseUrl || '';
              env.get = (key, fallback) => env[key] === undefined ? fallback : env[key];
              return env;
            };
            globalThis.utils_1 = {
              req: (url, options = {}) => {
                const raw = __http.request(String(url), JSON.stringify(options || {}));
                return typeof raw === 'string' ? JSON.parse(raw) : raw;
              },
              kitty: {
                load: __kittyLoad,
                utils: {
                  getM3u8WithIframe: async (env) => {
                    const url = env && (env.url || env.id || env.playUrl);
                    if (!url) return '';
                    const response = await globalThis.utils_1.req(url);
                    const body = response && (response.content || response.text || '');
                    const direct = String(body).match(/https?:[^"'\\s<>]+(?:m3u8|mp4)[^"'\\s<>]*/i);
                    if (direct) return direct[0].replace(/&amp;/g, '&');
                    const src = String(body).match(/(?:src|href)=["']([^"']+)["']/i);
                    return src ? src[1] : url;
                  }
                }
              }
            };
            // TVBox / drpy 契约里的全局 HTTP 入口（手机端 QuickJS 注入的是
            // 同步 http(url, options)，返回 { code, headers, content }）。
            globalThis.req = (url, options = {}) => globalThis.utils_1.req(url, options);
            globalThis.http = globalThis.req;
            """;

    private final String api;
    private final Map<String, String> scripts = new LinkedHashMap<>();
    private final Context context;

    public JavaScriptSpider(String api, String extraJson) {
        this.api = api == null ? "" : api;
        this.context = Context.newBuilder("js")
                .allowAllAccess(true)
                .allowHostAccess(HostAccess.ALL)
                .option("engine.WarnInterpreterOnly", "false")
                .build();
        context.getBindings("js").putMember("__http", new HttpBridge());
        context.getBindings("js").putMember("__htmlSelect", (ProxyExecutable) args ->
                HtmlKit.select(args[0].asString(), args[1].asString()));
        context.getBindings("js").putMember("__htmlFind", (ProxyExecutable) args ->
                HtmlKit.find(args[0].asString(), args[1].asString()));
        context.eval("js", BOOTSTRAP);
        initialize(extraJson);
    }

    @SuppressWarnings("unchecked")
    private void initialize(String extraJson) {
        Map<String, Object> extra = JsonCodec.parseObject(extraJson);
        Object jsValue = extra.get("js");
        Map<String, Object> js = jsValue instanceof Map ? (Map<String, Object>) jsValue : extra;
        for (String name : List.of("home", "category", "detail", "search",
                "play", "parseIframe", "live", "action")) {
            Object script = js.get(name);
            if (script != null && !String.valueOf(script).isBlank()) scripts.put(name, String.valueOf(script));
        }
        if (scripts.isEmpty()) throw new IllegalArgumentException("extra.js contains no supported scripts");
    }

    @Override
    public void init(android.content.Context context, String extend) {}

    @Override
    public String homeContent(boolean filter) { return call("home", env(Map.of("filter", filter))); }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, java.util.HashMap<String, String> extend) {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("tid", tid); values.put("pg", pg); values.put("page", pg); values.put("filter", filter);
        if (extend != null) values.putAll(extend);
        return call("category", env(values));
    }

    @Override
    public String detailContent(List<String> ids) {
        String id = ids == null || ids.isEmpty() ? "" : ids.get(0);
        return call("detail", env(Map.of("id", id)));
    }

    @Override
    public String searchContent(String key, boolean quick, String pg) {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("wd", key); values.put("key", key); values.put("pg", pg); values.put("page", pg); values.put("quick", quick);
        return call("search", env(values));
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("flag", flag); values.put("id", id); values.put("url", id); values.put("playUrl", id);
        // TVBox / drpy 生态导出 play(flag, id, vipFlags)；早期适配层只认
        // parseIframe，导致能进详情却拿不到播放地址。先 play，再回落 parseIframe。
        String result = call("play", env(values));
        if (!hasPayload(result)) result = call("parseIframe", env(values));
        return result;
    }

    @Override
    public String liveContent(String url) {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("url", url);
        values.put("id", url);
        return call("live", env(values));
    }

    @Override
    public String action(String action) {
        Map<String, Object> values = new LinkedHashMap<>();
        values.put("action", action);
        return call("action", env(values));
    }

    /** 判断脚本是否真的产出了内容；`{}`、空串与 error 载荷都算未产出。 */
    private static boolean hasPayload(String result) {
        if (result == null) return false;
        String trimmed = result.trim();
        if (trimmed.isEmpty() || "{}".equals(trimmed) || "[]".equals(trimmed)) return false;
        return !trimmed.contains("\"code\":-1");
    }

    @Override
    public void destroy() { context.close(); }

    private Map<String, Object> env(Map<String, ?> values) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("baseUrl", api); result.put("siteKey", siteKey);
        if (values != null) result.putAll(values);
        return result;
    }

    private String call(String name, Map<String, Object> environment) {
        String source = scripts.get(name);
        if (source == null) return "{}";
        String wrapped = "(() => { const module = {exports: {}}; const exports = module.exports; "
                + normalizeScript(source) + "\n"
                + "if (typeof home === 'function') module.exports.home = home;"
                + "if (typeof category === 'function') module.exports.category = category;"
                + "if (typeof detail === 'function') module.exports.detail = detail;"
                + "if (typeof search === 'function') module.exports.search = search;"
                + "if (typeof play === 'function') module.exports.play = play;"
                + "if (typeof parseIframe === 'function') module.exports.parseIframe = parseIframe;"
                + "if (typeof live === 'function') module.exports.live = live;"
                + "if (typeof action === 'function') module.exports.action = action;"
                + " return module.exports; })()";
        try {
            context.getBindings("js").putMember("__envJson", JsonCodec.stringify(environment));
            context.eval("js", "globalThis.env = __makeEnv(JSON.parse(__envJson))");
            Value exported = context.eval("js", wrapped);
            Value fn = findFunction(exported, name);
            if (fn == null) return "{}";
            Value result = fn.execute(context.getBindings("js").getMember("env"));
            if (result.hasMember("then")) result = awaitPromise(result);
            if (result.isString()) return result.asString();
            context.getBindings("js").putMember("__value", result);
            Value json = context.eval("js", "JSON.stringify(__value)");
            return json.isString() ? json.asString() : "{}";
        } catch (Throwable error) {
            Map<String, Object> fallback = new LinkedHashMap<>();
            fallback.put("code", -1);
            fallback.put("msg", error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage());
            fallback.put("list", List.of());
            return JsonCodec.stringify(fallback);
        }
    }

    private Value findFunction(Value exported, String name) {
        if (exported == null || exported.isNull()) return null;
        if (exported.canExecute()) return exported;
        if (exported.hasMember(name) && exported.getMember(name).canExecute()) return exported.getMember(name);
        if (exported.hasMember("default")) {
            Value value = exported.getMember("default");
            if (value.canExecute()) return value;
            if (value.hasMember(name) && value.getMember(name).canExecute()) return value.getMember(name);
        }
        return null;
    }

    private Value awaitPromise(Value promise) {
        final Value[] result = {null};
        final RuntimeException[] error = {null};
        promise.getMember("then").execute(
                (ProxyExecutable) args -> { result[0] = args.length == 0 ? null : args[0]; return null; },
                (ProxyExecutable) args -> { error[0] = new RuntimeException(args.length == 0 ? "Promise rejected" : args[0].toString()); return null; });
        for (int i = 0; i < 400 && result[0] == null && error[0] == null; i++) {
            try { Thread.sleep(5); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); break; }
        }
        if (error[0] != null) throw error[0];
        return result[0] == null ? context.eval("js", "undefined") : result[0];
    }

    private static String normalizeScript(String script) {
        String value = script.trim();
        value = value.replaceFirst("^export\\s+default\\s+", "module.exports.default = ");
        value = value.replaceAll("export\\s+async\\s+function\\s+([A-Za-z_$][\\w$]*)", "async function $1");
        value = value.replaceAll("export\\s+function\\s+([A-Za-z_$][\\w$]*)", "function $1");
        value = value.replaceAll("export\\s+\\{[^}]*};?", "");
        return value;
    }
}
