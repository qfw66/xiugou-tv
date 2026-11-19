package com.fongmi.companion;

import com.github.catvod.crawler.Spider;
import com.github.catvod.net.Net;
import com.github.catvod.net.NetOptions;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.HostAccess;
import org.graalvm.polyglot.Source;
import org.graalvm.polyglot.Value;
import org.graalvm.polyglot.io.IOAccess;
import org.graalvm.polyglot.proxy.ProxyExecutable;
import org.jsoup.Jsoup;
import org.jsoup.nodes.Element;

import java.io.ByteArrayOutputStream;
import java.io.InterruptedIOException;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Desktop implementation of GM's browser/user-script boundary, executing the original site rules. */
public final class GmSpider extends Spider {
    private static final String UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    private static final Pattern REQUIRE = Pattern.compile("(?m)^\\s*//\\s*@require\\s+(\\S+)");
    private static final Pattern TEMPLATE = Pattern.compile("\\$\\{([^}:]+)(?::-([^}]*))?}");
    private static final ScheduledExecutorService DEADLINES = Executors.newSingleThreadScheduledExecutor(task -> {
        Thread thread = new Thread(task, "gm-js-deadline");
        thread.setDaemon(true);
        return thread;
    });
    private final String extension;
    private final Map<String, String> storage = new LinkedHashMap<>();
    private final Map<String, GmPlayback.Reference> playback = new LinkedHashMap<>();
    private final Map<String, BrowserChallenge> browserChallenges = new LinkedHashMap<>();
    private final Map<String, BrowserVerificationSession> browserSessions = new java.util.concurrent.ConcurrentHashMap<>();
    private final AtomicReference<Context> active = new AtomicReference<>();
    private Map<String, Object> templates;
    private List<Source> scripts;
    private volatile boolean closed;
    private long timeoutMs;
    private String userAgent = UA;
    private GmPlayback.Site playbackSite = GmPlayback.Site.SCRIPT;
    private long playbackTtlMs;
    private volatile long callDeadline;

    /** The factory selects only the explicit csp_GM contract, before any Android jar is loaded. */
    static Spider create(String cleanApi, String ext) {
        return "GM".equals(cleanApi) ? new GmSpider(ext) : null;
    }

    public GmSpider(String ext) {
        extension = ext == null ? "" : ext;
    }

    @Override public synchronized void init(android.content.Context ignored, String ext) throws Exception {
        Map<String, Object> config = JsonCodec.parseObject(extension);
        String scriptUrl = text(config.get("userScript"));
        if (scriptUrl.isBlank() || !config.containsKey("spider")) throw new IllegalArgumentException("GM requires ext.userScript and ext.spider");
        templates = object(config.get("spider"));
        Map<String, Object> settings = object(config.get("webViewSettings"));
        String configuredUa = text(settings.get("userAgent"));
        if (!configuredUa.isBlank()) userAgent = configuredUa;
        timeoutMs = Math.max(250, Math.min(120_000, Long.getLong("xiugou.gm.timeoutMs", 45_000L)));
        playbackSite = GmPlayback.site(scriptUrl);
        playbackTtlMs = Math.max(250, Math.min(3_600_000, Long.getLong("xiugou.gm.playbackTtlMs", 1_800_000L)));
        beginCall();
        try {
            String source = download(scriptUrl);
            if (!source.contains("GmSpiderInject")) throw new IllegalArgumentException("GM userScript has no GmSpiderInject contract");
            scripts = new ArrayList<>();
            Matcher dependencies = REQUIRE.matcher(source);
            while (dependencies.find()) {
                String url = resolve(scriptUrl, dependencies.group(1));
                // jQuery's DOM methods are implemented by gm-runtime.js against jsoup.
                if (url.matches("(?i).*[/@]jquery(?:@|/|-|\\.).*")) continue;
                if (scripts.size() >= 16) throw new IllegalArgumentException("GM @require limit exceeded");
                scripts.add(Source.newBuilder("js", download(url), "gm-require-" + scripts.size() + ".js").build());
            }
            scripts.add(Source.newBuilder("js", source, "gm-user-script.js").build());
        } finally { callDeadline = 0; }
    }

    @Override public String homeContent(boolean filter) throws Exception {
        return call("homeContent", Map.of(), filter);
    }
    @Override public String homeVideoContent() { return "{\"list\":[]}"; }
    @Override public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        Map<String, Object> vars = new LinkedHashMap<>();
        vars.put("tid", tid); vars.put("pg", pg);
        if (extend != null) vars.putAll(extend); // Same ordering as GM.categoryContent.
        return call("categoryContent", vars, tid, pg, filter, extend == null ? Map.of() : extend);
    }
    @Override public String detailContent(List<String> ids) throws Exception {
        return call("detailContent", Map.of("id", ids.get(0)), ids);
    }
    @Override public String searchContent(String key, boolean quick) throws Exception {
        return searchContent(key, quick, "1");
    }
    @Override public String searchContent(String key, boolean quick, String pg) throws Exception {
        return call("searchContent", Map.of("key", key, "pg", pg), key, quick, pg);
    }
    @Override public synchronized String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        ensureInitialized();
        GmPlayback.Reference medium = playback.get(id);
        if (medium == null || medium.expired()) { playback.remove(id); throw GmPlayback.expired(); }
        beginCall();
        try {
            String result = GmPlayback.resolve(medium, flag == null ? "" : flag, vipFlags == null ? List.of() : vipFlags, new GmPlayback.Host() {
                @Override public Map<String, Object> request(String url, Map<String, Object> options) throws IOException { return GmSpider.this.request(url, options); }
                @Override public GmPlayback.ScriptResult player(GmPlayback.Reference ref, String selectedFlag, List<String> flags) throws Exception { return loadPlayer(ref, selectedFlag, flags); }
                @Override public String userAgent() { return userAgent; }
            });
            remainingMs(); // Never return a late response after close/cancel/deadline.
            Map<String, Object> value = JsonCodec.parseObject(result);
            String mediaUrl = text(value.get("url"));
            if (!mediaUrl.isBlank()) {
                URI media = GmPlayback.httpUrl(mediaUrl, "");
                BrowserVerificationSession session = browserSessions.get(BrowserChallenge.origin(media));
                if (session != null && session.verified()) {
                    Map<String, String> mediaHeaders = GmPlayback.headers(value.get("header"), session.playbackHeaders(media, remainingMs()));
                    value.put("header", mediaHeaders);
                    result = JsonCodec.stringify(value);
                }
            }
            remainingMs(); // Browser header lookup also belongs to this call's deadline.
            return result;
        } finally { callDeadline = 0; }
    }

    private GmPlayback.ScriptResult loadPlayer(GmPlayback.Reference ref, String flag, List<String> vipFlags) throws Exception {
        String template = text(object(templates.get("playerContent")).get("loadUrl"));
        if (template.isBlank()) return null;
        Map<String, Object> variables = new LinkedHashMap<>(ref.extra());
        variables.put("flag", flag);
        variables.putIfAbsent("id", ref.detailId());
        variables.putIfAbsent("ep", ref.episode());
        String url = GmPlayback.httpUrl(substitute(template, variables), ref.detailUrl()).toASCIIString();
        if (ref.site() != GmPlayback.Site.SCRIPT) url = GmPlayback.sameOrigin(url, ref.detailUrl());
        boolean retiredEpisodeApi = GmPlayback.isLegacyHuangGuoAiApi(ref, url);
        Map<String, Object> options = new LinkedHashMap<>();
        options.put("headers", GmPlayback.headers(ref.extra().get("header")));
        if (retiredEpisodeApi) options.put("_gmAllowRetiredEpisodeApi", true);
        Map<String, Object> response = request(url, options);
        int code = ((Number) response.getOrDefault("code", 0)).intValue();
        if (retiredEpisodeApi && (code == 404 || code == 410)) return null;
        GmPlayback.Page page = GmPlayback.Page.from(response);
        try {
            return new GmPlayback.ScriptResult(JsonCodec.parseObject(execute("playerContent", page, flag, ref.extra(), vipFlags)), page);
        } catch (UnsupportedOperationException error) {
            if (ref.site() == GmPlayback.Site.SCRIPT) throw error;
            // A recognized current API needs no click/dynamic browser even if its obsolete player does.
            remainingMs();
            return new GmPlayback.ScriptResult(Map.of(), page);
        }
    }

    private synchronized String call(String method, Map<String, ?> variables, Object... args) throws Exception {
        ensureInitialized();
        beginCall();
        try {
            String template = text(object(templates.get(method)).get("loadUrl"));
            if (template.isBlank()) throw new IllegalArgumentException("GM has no template for " + method);
            String url = substitute(template, variables);
            GmPlayback.Page page = GmPlayback.Page.from(request(url, Map.of()));
            return normalize(execute(method, page, args), method, variables, page);
        } finally { callDeadline = 0; }
    }

    private String execute(String method, GmPlayback.Page page, Object... args) throws Exception {
        String pageUrl = page.url();
        String html = page.content();
        GmHtml dom = new GmHtml(html);
        List<Object> arguments = new ArrayList<>();
        arguments.add(method);
        arguments.addAll(List.of(args));
        AtomicReference<String> output = new AtomicReference<>();
        AtomicReference<BrowserChallenge> verification = new AtomicReference<>();
        Context js = Context.newBuilder("js").allowHostAccess(HostAccess.NONE)
                .allowHostClassLookup(name -> false).allowIO(IOAccess.NONE)
                .allowCreateThread(false).allowNativeAccess(false)
                .option("engine.WarnInterpreterOnly", "false").build();
        active.set(js);
        if (closed) { active.compareAndSet(js, null); js.close(true); throw new IllegalStateException("GM spider closed"); }
        java.util.concurrent.ScheduledFuture<?> deadline = null;
        try {
            deadline = DEADLINES.schedule(() -> { try { js.close(true); } catch (RuntimeException ignored) {} }, remainingMs(), TimeUnit.MILLISECONDS);
            Value bindings = js.getBindings("js");
            bindings.putMember("__gmPageUrl", pageUrl);
            bindings.putMember("__gmUa", userAgent);
            bindings.putMember("__gmArgs", JsonCodec.stringify(arguments));
            bindings.putMember("__gmResult", (ProxyExecutable) values -> {
                String result = values[0].asString();
                if (result.length() > 8 * 1024 * 1024) throw new IllegalStateException("GM result exceeds 8 MB");
                output.set(result);
                return null;
            });
            bindings.putMember("__gmDom", (ProxyExecutable) values -> {
                String op = values[0].asString(), selector = values[2].asString();
                int node = values[1].asInt();
                return switch (op) {
                    case "select" -> dom.select(selector);
                    case "find" -> dom.find(node, selector);
                    case "body" -> dom.body();
                    case "children" -> dom.children(node, selector);
                    case "next" -> dom.adjacent(node, selector, 1);
                    case "prev" -> dom.adjacent(node, selector, -1);
                    case "parent" -> dom.parent(node, selector);
                    case "closest" -> dom.closest(node, selector);
                    case "matches" -> String.valueOf(dom.matches(node, selector));
                    case "snapshot" -> dom.snapshot(node);
                    case "remove" -> { dom.remove(node); yield "null"; }
                    default -> throw new IllegalArgumentException("Unknown GM DOM operation");
                };
            });
            bindings.putMember("__gmUrl", (ProxyExecutable) values -> urlJson(values[0].asString(), values[1].asString()));
            bindings.putMember("__gmFetch", (ProxyExecutable) values -> {
                try { return JsonCodec.stringify(request(values[0].asString(), JsonCodec.parseObject(values[1].asString()))); }
                catch (IOException error) { if (error instanceof BrowserChallenge challenge) verification.set(challenge); throw new IllegalStateException(error.getMessage(), error); }
            });
            bindings.putMember("__gmBase64", (ProxyExecutable) values -> values[1].asBoolean()
                    ? Base64.getEncoder().encodeToString(values[0].asString().getBytes(StandardCharsets.ISO_8859_1))
                    : new String(Base64.getDecoder().decode(values[0].asString()), StandardCharsets.ISO_8859_1));
            bindings.putMember("__gmStorage", (ProxyExecutable) values -> {
                String key = values[0].asString();
                return switch (values[2].asString()) {
                    case "get" -> storage.get(key);
                    case "remove" -> storage.remove(key);
                    case "clear" -> { storage.clear(); yield null; }
                    case "set" -> { if (storage.size() < 256 && values[1].asString().length() <= 65536) storage.put(key, values[1].asString()); yield null; }
                    default -> null;
                };
            });
            js.eval("js", bootstrap());
            for (Source script : scripts) js.eval(script);
            // Static inline page globals (for unsafeWindow.hlsUrl etc.) execute in the guest realm.
            int pageErrors = 0;
            for (Element script : Jsoup.parse(html).select("script:not([src])")) {
                String type = script.attr("type").toLowerCase(Locale.ROOT);
                if (!type.isEmpty() && !type.equals("text/javascript") && !type.equals("application/javascript")) continue;
                if (script.data().isBlank()) continue;
                try { js.eval(Source.newBuilder("js", script.data(), "gm-page-inline.js").build()); }
                catch (org.graalvm.polyglot.PolyglotException error) { if (error.isCancelled()) throw error; pageErrors++; }
            }
            js.eval("js", "__gmReady()");
            while (output.get() == null) {
                remainingMs();
                js.eval("js", "__gmTick()");
                Value asyncError = bindings.getMember("__gmAsyncError");
                if (verification.get() != null) throw verification.get();
                if (asyncError != null && !asyncError.isNull()) {
                    if (method.equals("playerContent")) throw new UnsupportedOperationException("GM original playerContent failed; no main media URL (browser-only behavior unsupported)");
                    throw new IllegalStateException("GM userScript: " + asyncError.asString());
                }
                if (output.get() == null) Thread.sleep(10);
            }
            if (output.get() == null) throw new IllegalStateException("GM userScript did not call SetSpiderResult; browser-dependent page, inlineErrors=" + pageErrors);
            if (verification.get() != null) throw verification.get();
            return output.get();
        } catch (org.graalvm.polyglot.PolyglotException error) {
            if (verification.get() != null) throw verification.get();
            if (error.isCancelled()) throw new IllegalStateException("GM script timed out or was canceled", error);
            if (method.equals("playerContent")) throw new UnsupportedOperationException("GM desktop: original playerContent requires unsupported browser behavior; no main media URL");
            throw new IllegalStateException("GM userScript execution failed: " + error.getMessage(), error);
        } finally {
            if (deadline != null) deadline.cancel(false);
            active.compareAndSet(js, null);
            js.close(true);
        }
    }

    private String normalize(String raw, String method, Map<String, ?> variables, GmPlayback.Page page) {
        Map<String, Object> value = JsonCodec.parseObject(raw);
        if (value.isEmpty()) throw new IllegalArgumentException("GM userScript returned no JSON object");
        // Some scripts (netflav) return the vod itself instead of {list:[vod]}.
        if (method.equals("detailContent") && !value.containsKey("list") && value.containsKey("vod_id")) {
            Map<String, Object> wrapped = new LinkedHashMap<>();
            wrapped.put("list", new ArrayList<>(List.of(value)));
            value = wrapped;
        }
        if (method.equals("detailContent") && value.get("list") instanceof List<?> rows) {
            for (Object row : rows) {
                Map<String, Object> vod = object(row);
                List<?> groups = vod.get("vod_play_data") instanceof List<?> rowsOfGroups ? rowsOfGroups : List.of();
                if (groups.isEmpty() && playbackSite == GmPlayback.Site.NETFLAV && GmPlayback.hasNetflavDetail(page)) {
                    groups = List.of(Map.of("from", "GM", "media", List.of(Map.of("name", "Main", "type", "deferred", "ext", Map.of()))));
                }
                if (groups.isEmpty()) continue;
                String detailId = text(vod.getOrDefault("vod_id", variables.get("id")));
                List<String> flags = new ArrayList<>(), playlists = new ArrayList<>();
                for (Object group : groups) {
                    Map<String, Object> data = object(group);
                    if (!(data.get("media") instanceof List<?> media)) continue;
                    List<String> episodes = new ArrayList<>();
                    for (Object item : media) {
                        Map<String, Object> medium = object(item);
                        GmPlayback.Reference reference = GmPlayback.reference(playbackSite, medium, text(data.get("from")), detailId, page, playbackTtlMs);
                        if (reference == null) continue;
                        String token = "gm_" + java.util.UUID.randomUUID().toString().replace("-", "");
                        if (playback.size() >= 2048) playback.remove(playback.keySet().iterator().next());
                        playback.put(token, reference);
                        episodes.add(text(medium.get("name")).replace('$', ' ').replace('#', ' ') + "$" + token);
                    }
                    if (!episodes.isEmpty()) { flags.add(text(data.get("from"))); playlists.add(String.join("#", episodes)); }
                }
                vod.put("vod_play_from", String.join("$$$", flags));
                vod.put("vod_play_url", String.join("$$$", playlists));
            }
        }
        return JsonCodec.stringify(value);
    }
    synchronized Map<String, Object> browserVerification(String id, String operation, String proxy) throws IOException {
        if (closed) throw new IOException("GM spider closed");
        BrowserChallenge challenge = browserChallenges.get(id);
        if (challenge == null) throw new IllegalArgumentException("Unknown or stale verification request");
        String origin = BrowserChallenge.origin(challenge.url);
        BrowserVerificationSession session = browserSessions.get(origin);
        if ("cancel".equals(operation)) {
            if (session != null) { browserSessions.remove(origin); session.close(); }
            browserChallenges.remove(id);
            return Map.of("state", "cancelled");
        }
        if ("open".equals(operation)) {
            if (session != null) { browserSessions.remove(origin); session.close(); }
            if (browserSessions.size() >= 4) {
                String oldest = browserSessions.keySet().iterator().next();
                browserSessions.remove(oldest).close();
            }
            session = BrowserVerificationSession.open(challenge.url, proxy);
            if (closed || Thread.currentThread().isInterrupted()) { session.close(); throw new InterruptedIOException("Verification canceled"); }
            browserSessions.put(origin, session);
            return Map.of("state", "waiting", "origin", origin);
        }
        if ("complete".equals(operation)) {
            if (session == null) return Map.of("state", "required");
            if (!session.complete(challenge.url, timeoutMs)) return Map.of("state", "waiting");
            userAgent = session.userAgent();
            return Map.of("state", "verified", "origin", origin);
        }
        throw new IllegalArgumentException("Unknown verification operation");
    }


    private String download(String url) throws IOException {
        return text(request(url, Map.of()).get("content"));
    }

    private Map<String, Object> request(String url, Map<String, Object> options) throws IOException {
        remainingMs();
        URI uri = GmPlayback.httpUrl(url, "");
        // The DOM engine cannot execute media or decode images; resolution only fetches text metadata.
        if (uri.getPath().matches("(?i).*\\.(?:jpg|jpeg|png|webp|gif|mp4|m3u8|mpd|m4s|ts|webm)(?:/)?$")) throw new IOException("GM desktop: image/media body unsupported");
        Map<String, String> headers = GmPlayback.headers(Map.of("User-Agent", userAgent, "Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8"), options.get("headers"));
        Map<String, Object> req = new LinkedHashMap<>();
        req.put("headers", headers);
        req.put("logMetadataOnly", true);
        req.put("timeout", Math.min(15_000, remainingMs())); req.put("callTimeout", Math.min(20_000, remainingMs()));
        req.put("method", text(options.getOrDefault("method", "GET")));
        if (options.containsKey("body")) req.put("body", options.get("body"));
        Map<String, Object> response;
        try { response = requestText(uri, req); }
        catch (IOException error) {
            remainingMs(); // Cancellation and the shared deadline are call errors, not upstream failures.
            ParseStage.fail(ParseStage.UPSTREAM, "GM " + uri.getHost() + ": " + error.getClass().getSimpleName());
            throw new IOException("GM " + uri.getHost() + " network request failed or was canceled");
        }
        int code = ((Number) response.getOrDefault("code", 0)).intValue();
        if (BrowserChallenge.detected(response)) {
            URI target = GmPlayback.httpUrl(text(response.getOrDefault("url", uri.toASCIIString())), "");
            String origin = BrowserChallenge.origin(target);
            BrowserVerificationSession session = browserSessions.get(origin);
            if (session != null) session.invalidate();
            BrowserChallenge challenge = browserChallenges.values().stream()
                    .filter(value -> value.url.equals(target)).findFirst().orElse(null);
            if (challenge == null) {
                challenge = new BrowserChallenge(target);
                if (browserChallenges.size() >= 8) browserChallenges.remove(browserChallenges.keySet().iterator().next());
                browserChallenges.put(challenge.id, challenge);
            }
            throw challenge;
        }
        if ((code < 200 || code >= 400) && !(code == 409 && Boolean.TRUE.equals(options.get("_gmAllow409"))) &&
                !((code == 404 || code == 410) && Boolean.TRUE.equals(options.get("_gmAllowRetiredEpisodeApi")))) {
            String reason = "GM " + uri.getHost() + " HTTP " + code;
            ParseStage.fail(ParseStage.UPSTREAM, reason);
            throw new IOException(reason);
        }
        remainingMs();
        return response;
    }

    private Map<String, Object> requestText(URI uri, Map<String, Object> options) throws IOException {
        String origin = BrowserChallenge.origin(uri);
        BrowserVerificationSession session = browserSessions.get(origin);
        if (session != null && session.verified()) {
            try { return session.request(uri, options, remainingMs()); }
            catch (IOException error) {
                remainingMs();
                browserSessions.remove(origin, session);
                session.close();
                if (!"GET".equalsIgnoreCase(text(options.getOrDefault("method", "GET")))) throw error;
            }
        }
        return readText(net.requestStreamAsync(uri.toASCIIString(), NetOptions.from(JsonCodec.stringify(options))));
    }

    Map<String, Object> readText(CompletableFuture<Net.StreamResult> pending) throws IOException {
        AtomicReference<Net.StreamResult> body = new AtomicReference<>();
        Thread owner = Thread.currentThread();
        // Reuse the existing host deadline scheduler; no guest threads or unowned HTTP client.
        var cancellation = DEADLINES.scheduleWithFixedDelay(() -> {
            if (closed || owner.isInterrupted() || (callDeadline != 0 && System.nanoTime() >= callDeadline)) {
                pending.cancel(true);
                Net.StreamResult stream = body.get();
                if (stream != null) stream.close();
            }
        }, 10, 10, TimeUnit.MILLISECONDS);
        try (Net.StreamResult stream = pending.get(remainingMs(), TimeUnit.MILLISECONDS)) {
            body.set(stream);
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int count;
            while ((count = stream.read(chunk)) != -1) {
                remainingMs();
                if (bytes.size() + count > 8 * 1024 * 1024) throw new IOException("GM text response exceeds 8 MB");
                bytes.write(chunk, 0, count);
            }
            remainingMs();
            okhttp3.MediaType mediaType = okhttp3.MediaType.parse(stream.headers.getOrDefault("content-type", "text/plain"));
            var charset = mediaType == null ? StandardCharsets.UTF_8 : mediaType.charset(StandardCharsets.UTF_8);
            Map<String, Object> response = new LinkedHashMap<>();
            response.put("code", stream.code); response.put("headers", stream.headers);
            response.put("url", stream.url); response.put("content", bytes.toString(charset));
            return response;
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new InterruptedIOException("GM call canceled");
        } catch (ExecutionException | TimeoutException | java.util.concurrent.CancellationException error) {
            throw new IOException("GM network request timed out or was canceled");
        } finally {
            cancellation.cancel(false);
            // cancel() cannot reclaim an already-completed response that failed before body binding.
            pending.thenAccept(Net.StreamResult::close);
            pending.cancel(true);
        }
    }

    private void ensureInitialized() {
        if (closed || scripts == null) throw new IllegalStateException("GM spider is not initialized");
    }
    private void beginCall() { callDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs); }
    private long remainingMs() throws IOException {
        if (closed || Thread.currentThread().isInterrupted()) throw new InterruptedIOException("GM call canceled or spider closed");
        long left = callDeadline == 0 ? timeoutMs : TimeUnit.NANOSECONDS.toMillis(callDeadline - System.nanoTime());
        if (left <= 0) throw new IOException("GM call timed out");
        return left;
    }

    static String substitute(String template, Map<String, ?> vars) {
        Matcher matcher = TEMPLATE.matcher(template);
        StringBuffer result = new StringBuffer();
        while (matcher.find()) {
            Object value = vars.get(matcher.group(1));
            String replacement = value == null ? matcher.group(2) : String.valueOf(value);
            if (replacement == null) throw new IllegalArgumentException("GM missing template variable: " + matcher.group(1));
            matcher.appendReplacement(result, Matcher.quoteReplacement(replacement));
        }
        matcher.appendTail(result);
        return result.toString();
    }

    private static String urlJson(String raw, String base) {
        URI uri = URI.create(raw.replace(" ", "%20"));
        if (!base.isEmpty()) uri = URI.create(base).resolve(uri);
        if (!uri.isAbsolute()) throw new IllegalArgumentException("Invalid URL");
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("href", uri.toASCIIString()); value.put("protocol", uri.getScheme() + ":");
        value.put("hostname", uri.getHost()); value.put("host", uri.getRawAuthority());
        value.put("origin", uri.getScheme() + "://" + uri.getRawAuthority());
        value.put("pathname", uri.getRawPath().isEmpty() ? "/" : uri.getRawPath());
        value.put("search", uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery());
        value.put("hash", uri.getRawFragment() == null ? "" : "#" + uri.getRawFragment());
        return JsonCodec.stringify(value);
    }

    static String resolve(String base, String relative) { return URI.create(base).resolve(relative).toString(); }
    private static String text(Object value) { return value == null ? "" : String.valueOf(value); }
    @SuppressWarnings("unchecked") private static Map<String, Object> object(Object value) {
        return value instanceof Map<?, ?> ? (Map<String, Object>) value : new LinkedHashMap<>();
    }
    private static String bootstrap() throws IOException {
        try (InputStream in = GmSpider.class.getResourceAsStream("/gm-runtime.js")) {
            if (in == null) throw new IOException("GM runtime resource missing");
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
    @Override public void destroy() {
        closed = true;
        Context js = active.getAndSet(null);
        if (js != null) try { js.close(true); } catch (RuntimeException ignored) {}
        closeHostResources();
        for (BrowserVerificationSession session : browserSessions.values()) session.close();
        synchronized (this) { storage.clear(); playback.clear(); scripts = null; browserSessions.clear(); browserChallenges.clear(); }
    }
}
