package com.fongmi.companion;

import org.jsoup.Jsoup;
import org.jsoup.nodes.Element;

import java.io.IOException;
import java.net.URI;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** The GM -> CatVod playback boundary. Only explicit media contracts become parse=0 URLs. */
final class GmPlayback {
    enum Site { SCRIPT, JAVTIFUL, HUANGGUOAI, AIHUANGDOU, PORNCGW, NETFLAV }
    enum Type { DIRECT, FINAL_URL, WEBVIEW, MATCH, DEFERRED, UNKNOWN }

    /** Never stores a ticket or a resolved API signature: every native resolution is fresh. */
    record Reference(Type type, Map<String, Object> extra, String flag, String detailId,
                     String detailUrl, String origin, String episode, Site site, long expires) {
        String url() { return text(extra.get("url")); }
        boolean expired() { return System.nanoTime() >= expires; }
    }
    record Page(String url, String content) {
        static Page from(Map<String, Object> response) {
            return new Page(text(response.get("url")), text(response.get("content")));
        }
    }
    record ScriptResult(Map<String, Object> value, Page page) {}

    /** All HTTP and guest execution remain owned/canceled/budgeted by the GmSpider instance. */
    interface Host {
        Map<String, Object> request(String url, Map<String, Object> options) throws IOException;
        ScriptResult player(Reference reference, String flag, List<String> vipFlags) throws Exception;
        String userAgent();
    }

    private static final Pattern OLD_EPISODE_API = Pattern.compile("^/api/videos/([1-9]\\d{0,18})/play/?$");
    private static final Pattern VIDEO_PAGE = Pattern.compile("^/video/([1-9]\\d{0,18})(?:/([1-9]\\d{0,18}))?/?$");
    private static final Pattern POST_PAGE = Pattern.compile("^/(post|video|drama)/([1-9]\\d{0,18})(?:/([1-9]\\d{0,18}))?/?$");
    private static final Pattern HEADER_NAME = Pattern.compile("[!#$%&'*+.^_`|~0-9A-Za-z-]+");

    private GmPlayback() {}

    static Site site(String scriptUrl) {
        String path = URI.create(scriptUrl).getPath().toLowerCase(java.util.Locale.ROOT);
        String file = path.substring(path.lastIndexOf('/') + 1);
        return switch (file) {
            case "javtiful.user.js" -> Site.JAVTIFUL;
            case "huangguoai.user.js" -> Site.HUANGGUOAI;
            case "aihuangdou.user.js" -> Site.AIHUANGDOU;
            case "porncgw.user.js" -> Site.PORNCGW;
            case "netflav.user.js" -> Site.NETFLAV;
            default -> Site.SCRIPT;
        };
    }

    static Reference reference(Site site, Map<String, Object> medium, String flag, String detailId, Page page, long ttlMs) {
        Map<String, Object> extra = immutable(object(medium.get("ext")));
        Type type = switch (text(medium.get("type"))) {
            case "direct" -> Type.DIRECT;
            case "finalUrl" -> Type.FINAL_URL;
            case "webview" -> Type.WEBVIEW;
            case "match" -> Type.MATCH;
            case "deferred" -> Type.DEFERRED;
            default -> Type.UNKNOWN;
        };
        String url = text(extra.get("url"));
        // An empty arbitrary URL is not a license to guess a player page.
        if (url.isBlank() && !(site == Site.JAVTIFUL && hasTicketContract(page)) && site != Site.NETFLAV) return null;
        String ep = text(extra.get("ep"));
        if (!url.isBlank() && (site == Site.HUANGGUOAI || site == Site.AIHUANGDOU || site == Site.PORNCGW)) {
            URI selected = httpUrl(url, page.url());
            if (site == Site.HUANGGUOAI) ep = query(selected, "ep");
            else if (site == Site.AIHUANGDOU) {
                Matcher route = VIDEO_PAGE.matcher(selected.getPath());
                if (route.matches()) ep = text(route.group(2));
            } else if (site == Site.PORNCGW) {
                Matcher route = POST_PAGE.matcher(selected.getPath());
                if (route.matches()) ep = text(route.group(3));
            }
        }
        return new Reference(type, extra, flag, detailId, page.url(), origin(page.url()), ep, site,
                System.nanoTime() + java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(ttlMs));
    }

    static boolean hasTicketContract(Page page) {
        Map<String, Object> playback = object(jsonElement(page, "watch-config").get("playback"));
        return !text(playback.get("endpoint")).isBlank() && !text(playback.get("ticket")).isBlank();
    }

    static boolean hasNetflavDetail(Page page) {
        Map<String, Object> root = jsonElement(page, "__NEXT_DATA__");
        return object(object(object(root.get("props")).get("initialState")).get("video")).get("data") instanceof Map<?, ?>;
    }

    static String resolve(Reference ref, String flag, List<String> vipFlags, Host host) throws Exception {
        if (ref.expired()) throw expired();
        if ((ref.type() == Type.DIRECT || ref.type() == Type.FINAL_URL) && !ref.url().isBlank()) {
            return direct(ref.url(), ref.detailUrl(), headers(ref.extra().get("header")), ref.detailUrl());
        }
        if (ref.site() == Site.JAVTIFUL) return ticket(ref, host);
        if (ref.site() == Site.NETFLAV) {
            // src/srcs/otherSrcs/uSrc/premium are empty in the verified current main record.
            // related2.previewVideo and advertising iframes must never supply the main film.
            throw new UnsupportedOperationException("GM desktop: netflav main source unavailable; browser/provider resolution unsupported (previews and ads excluded)");
        }

        ScriptResult original = host.player(ref, flag.isBlank() ? ref.flag() : flag, vipFlags);
        // Current first-party APIs supersede stale video_url/inlineUrl and old browser matchers.
        // The original player still runs with its selected ext and loadUrl, not our opaque token.
        return switch (ref.site()) {
            case HUANGGUOAI -> huangGuoAi(ref, original, host);
            case AIHUANGDOU -> aiHuangDou(ref, original, host);
            case PORNCGW -> porncgw(ref, original, host);
            default -> flatten(ref, original);
        };
    }

    private static String flatten(Reference ref, ScriptResult result) {
        if (result == null) throw browser(ref.type());
        Map<String, Object> value = result.value(), extra = object(value.get("ext"));
        String type = text(value.get("type"));
        if (!type.equals("direct") && !type.equals("finalUrl")) {
            if (type.equals("match") || type.equals("webview")) throw browser(type.equals("match") ? Type.MATCH : Type.WEBVIEW);
            throw new UnsupportedOperationException("GM desktop: playerContent did not return a main media URL; browser-dependent playback unsupported");
        }
        if (text(extra.get("url")).isBlank()) throw new IllegalStateException("GM playerContent returned no main media URL; reload detail");
        return direct(text(extra.get("url")), result.page().url(), headers(ref.extra().get("header"), extra.get("header")),
                ref.detailUrl(), result.page().url());
    }

    private static String ticket(Reference ref, Host host) throws IOException {
        Page page = Page.from(host.request(ref.detailUrl(), Map.of()));
        Map<String, Object> playback = object(jsonElement(page, "watch-config").get("playback"));
        String ticket = text(playback.get("ticket")), endpoint = text(playback.get("endpoint"));
        if (ticket.isBlank() || endpoint.isBlank()) throw new IllegalStateException("GM Javtiful playback ticket unavailable; reload detail");
        String api = sameOrigin(endpoint, page.url());
        for (int attempt = 0; attempt < 2; attempt++) {
            Map<String, Object> response = host.request(api, Map.of("method", "POST", "body", "ticket=" + URLEncoder.encode(ticket, StandardCharsets.UTF_8),
                    "headers", apiHeaders(page.url(), host.userAgent(), "application/x-www-form-urlencoded;charset=UTF-8"), "_gmAllow409", true));
            Map<String, Object> data = json(text(response.get("content")));
            if (number(response.get("code")) == 409 && attempt == 0 && !text(data.get("renewTicket")).isBlank()) {
                ticket = text(data.get("renewTicket"));
                continue;
            }
            if (number(response.get("code")) < 200 || number(response.get("code")) >= 300 || !Boolean.TRUE.equals(data.get("success"))) throw new IllegalStateException("GM Javtiful playback ticket expired or main source unavailable; reload detail");
            Object sources = data.get("sources");
            if (sources instanceof List<?> rows) {
                for (Object row : rows) {
                    Map<String, Object> source = object(row);
                    if (!"video/mp4".equalsIgnoreCase(text(source.get("type"))) || text(source.get("src")).isBlank() ||
                            Boolean.TRUE.equals(source.get("preview")) || "preview".equalsIgnoreCase(text(source.get("role")))) continue;
                    // The current MP4 src is relative and extensionless. Its explicit MIME, not an extension guess, identifies media.
                    return direct(text(source.get("src")), origin(page.url()) + "/",
                            headers(Map.of("Referer", page.url(), "User-Agent", host.userAgent()), ref.extra().get("header"), source.get("header")),
                            page.url(), api);
                }
            }
            throw new IllegalStateException("GM Javtiful returned no main video/mp4 source; reload detail");
        }
        throw new IllegalStateException("GM Javtiful playback ticket expired; reload detail");
    }

    static boolean isLegacyHuangGuoAiApi(Reference ref, String url) {
        if (ref.site() != Site.HUANGGUOAI) return false;
        URI selected = httpUrl(url, "");
        Matcher route = OLD_EPISODE_API.matcher(selected.getPath());
        return route.matches() && origin(url).equalsIgnoreCase(ref.origin()) &&
                route.group(1).equals(ref.detailId()) && !ref.episode().isBlank() &&
                query(selected, "ep").equals(ref.episode());
    }

    private static String huangGuoAi(Reference ref, ScriptResult original, Host host) throws IOException {
        URI selected = httpUrl(sameOrigin(ref.url(), ref.detailUrl()), "");
        Matcher route = OLD_EPISODE_API.matcher(selected.getPath());
        if (!route.matches()) throw contract("HuangGuoAi selected episode API");
        if (!positiveId(route.group(1)).equals(positiveId(ref.detailId()))) throw contract("HuangGuoAi detail/selected media mismatch");
        String ep = positiveId(ref.episode());
        String api = ref.origin() + "/api/videos/" + positiveId(route.group(1)) + "/episodes/" + ep + "/playback";
        return hls(ref, original, host, api, ref.detailUrl());
    }

    private static String aiHuangDou(Reference ref, ScriptResult original, Host host) throws IOException {
        String selected = sameOrigin(ref.url(), ref.detailUrl());
        Page page = original == null ? Page.from(host.request(selected, Map.of())) : original.page();
        sameOrigin(page.url(), selected);
        Matcher route = VIDEO_PAGE.matcher(httpUrl(page.url(), "").getPath());
        if (!route.matches()) throw contract("AiHuangDou selected page");
        Map<String, Object> data = jsonElement(page, "ninePlayData");
        String id = positiveId(text(data.get("id")));
        // Exactly services/playback.episode(data.id, curEp()), curEp = parseInt(data.startEp, 10) || 1.
        String ep = startEpisode(data.get("startEp"));
        if (!id.equals(route.group(1)) || !id.equals(positiveId(ref.detailId())) || (!ref.episode().isBlank() && !ep.equals(positiveId(ref.episode())))) {
            throw contract("AiHuangDou page/selected episode mismatch");
        }
        String api = origin(page.url()) + "/api/videos/" + id + "/episodes/" + ep + "/playback";
        return hls(ref, original, host, api, page.url());
    }

    private static String porncgw(Reference ref, ScriptResult original, Host host) throws IOException {
        URI selected = httpUrl(sameOrigin(ref.url(), ref.detailUrl()), "");
        Matcher route = POST_PAGE.matcher(selected.getPath());
        if (!route.matches()) throw contract("porncgw selected page");
        String kind = route.group(1), id = positiveId(route.group(2));
        if (!(kind + "/" + id).equals(ref.detailId().replaceAll("^/+|/+$", ""))) throw contract("porncgw detail/selected media mismatch");
        String path;
        if (kind.equals("drama")) path = "/api/videos/" + id + "/episodes/" + positiveId(ref.episode()) + "/playback";
        else path = (kind.equals("post") ? "/api/posts/" : "/api/videos/") + id + "/playback";
        return hls(ref, original, host, ref.origin() + path, selected.toASCIIString());
    }

    private static String hls(Reference ref, ScriptResult original, Host host, String api, String referer) throws IOException {
        Map<String, Object> response = host.request(api, Map.of("method", "POST", "body", "{}",
                "headers", apiHeaders(referer, host.userAgent(), "application/json")));
        Map<String, Object> envelope = json(text(response.get("content")));
        if (number(response.get("code")) < 200 || number(response.get("code")) >= 300 || number(envelope.get("status")) != 1) throw new IllegalStateException("GM playback API rejected the selected main episode; reload detail");
        Map<String, Object> data = object(envelope.get("data"));
        if (!"GET".equals(data.get("manifest_method"))) throw contract("playback manifest method");
        String main = text(object(data.get("streams")).get("main"));
        if (main.isBlank()) throw new IllegalStateException("GM playback API returned no main stream (preview excluded); reload detail");
        Map<String, Object> playerExtra = original == null ? Map.of() : object(original.value().get("ext"));
        Map<String, String> headers = headers(Map.of("Referer", origin(referer) + "/", "User-Agent", host.userAgent()),
                ref.extra().get("header"), playerExtra.get("header"));
        Map<String, Object> cdn = object(data.get("cdn"));
        String absolute = httpUrl(main, origin(referer) + "/").toASCIIString();
        // The actual frontend services/playback.xhrSetup contract (not the obsolete userscript comment).
        if (Boolean.TRUE.equals(cdn.get("m3u8Enabled")) && absolute.matches("(?i).*\\.m3u8(?:[?#].*)?$") &&
                !text(cdn.get("authKey")).isBlank() && !text(cdn.get("authValue")).isBlank() && !text(cdn.get("app")).isBlank()) {
            headers = headers(headers, Map.of(text(cdn.get("authKey")), text(cdn.get("authValue")), "x-cdn-app", text(cdn.get("app"))));
        }
        return direct(absolute, referer, headers, ref.detailUrl(), api, referer);
    }

    private static Map<String, String> apiHeaders(String referer, String ua, String contentType) {
        return Map.of("Content-Type", contentType, "Accept", "application/json", "X-Requested-With", "XMLHttpRequest", "Referer", referer, "User-Agent", ua);
    }

    private static String direct(String raw, String base, Map<String, String> headers, String... pages) {
        if (raw.isBlank()) throw new IllegalStateException("GM returned no main media URL; reload detail");
        URI uri = httpUrl(raw, base);
        String path = uri.getPath().toLowerCase(java.util.Locale.ROOT);
        if (path.equals("/api") || path.startsWith("/api/") || path.matches(".*\\.(?:html?|php|aspx?)/?$")) throw contract("API/HTML address is not media");
        String address = uri.toASCIIString();
        for (String page : pages) if (!page.isBlank() && withoutFragment(address).equals(withoutFragment(httpUrl(page, base).toASCIIString()))) {
            throw contract("player page is not media");
        }
        return JsonCodec.stringify(Map.of("parse", 0, "url", address, "header", headers));
    }

    static Map<String, String> headers(Object... sources) {
        Map<String, String> result = new LinkedHashMap<>();
        for (Object source : sources) {
            if (source instanceof String raw) source = json(raw);
            for (Map.Entry<String, Object> entry : object(source).entrySet()) {
                String name = entry.getKey(), value = text(entry.getValue());
                if (!HEADER_NAME.matcher(name).matches() || value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0 || value.indexOf('\0') >= 0) throw contract("invalid playback header");
                result.keySet().removeIf(key -> key.equalsIgnoreCase(name));
                result.put(name, value);
            }
        }
        return result;
    }

    static URI httpUrl(String raw, String base) {
        try {
            URI uri = URI.create(raw.replace(" ", "%20"));
            if (!uri.isAbsolute() && !base.isBlank()) uri = URI.create(base).resolve(uri);
            if ((!"http".equalsIgnoreCase(uri.getScheme()) && !"https".equalsIgnoreCase(uri.getScheme())) || uri.getHost() == null || uri.getRawUserInfo() != null) throw contract("expected absolute HTTP(S) URL");
            return uri;
        } catch (IllegalArgumentException error) { throw contract("expected absolute HTTP(S) URL"); }
    }

    static String sameOrigin(String raw, String page) {
        String url = httpUrl(raw, page).toASCIIString();
        if (!origin(url).equalsIgnoreCase(origin(page))) throw contract("cross-origin playback API/page unsupported");
        return url;
    }
    private static String origin(String url) { URI uri = httpUrl(url, ""); return uri.getScheme() + "://" + uri.getRawAuthority(); }
    private static String withoutFragment(String url) { int hash = url.indexOf('#'); return hash < 0 ? url : url.substring(0, hash); }
    private static String query(URI uri, String name) {
        if (uri.getRawQuery() != null) for (String field : uri.getRawQuery().split("&")) {
            String[] pair = field.split("=", 2);
            if (URLDecoder.decode(pair[0], StandardCharsets.UTF_8).equals(name)) return pair.length == 2 ? URLDecoder.decode(pair[1], StandardCharsets.UTF_8) : "";
        }
        return "";
    }
    private static String positiveId(String value) {
        if (!value.matches("[1-9]\\d{0,18}") || (value.length() == 19 && value.compareTo("9223372036854775807") > 0)) throw contract("invalid selected media id/episode");
        return value;
    }
    private static String startEpisode(Object value) {
        Matcher integer = Pattern.compile("^[\\s]*([+-]?\\d+)").matcher(text(value));
        if (!integer.find()) return "1";
        try {
            long parsed = Long.parseLong(integer.group(1));
            return parsed == 0 ? "1" : positiveId(Long.toString(parsed));
        } catch (NumberFormatException error) { throw contract("invalid page start episode"); }
    }
    private static Map<String, Object> jsonElement(Page page, String id) {
        Element element = Jsoup.parse(page.content()).getElementById(id);
        return element == null ? Map.of() : json(element.data().isBlank() ? element.html() : element.data());
    }
    private static Map<String, Object> json(String raw) {
        try { return JsonCodec.parseObject(raw); }
        catch (RuntimeException error) { throw contract("invalid playback metadata JSON"); }
    }
    private static Map<String, Object> immutable(Map<String, Object> value) {
        Map<String, Object> copy = new LinkedHashMap<>();
        value.forEach((key, entry) -> copy.put(key, copyValue(entry)));
        return Collections.unmodifiableMap(copy);
    }
    private static Object copyValue(Object value) {
        if (value instanceof Map<?, ?>) return immutable(object(value));
        if (value instanceof List<?> list) {
            List<Object> copy = new ArrayList<>();
            list.forEach(item -> copy.add(copyValue(item)));
            return Collections.unmodifiableList(copy);
        }
        return value;
    }
    static IllegalArgumentException expired() { return new IllegalArgumentException("GM playback reference expired; reload detail"); }
    private static UnsupportedOperationException browser(Type type) { return new UnsupportedOperationException("GM desktop: " + type.name().toLowerCase(java.util.Locale.ROOT) + " playback requires an unsupported browser; no main media URL"); }
    private static IllegalStateException contract(String reason) { return new IllegalStateException("GM playback contract: " + reason); }
    private static int number(Object value) { return value instanceof Number n ? n.intValue() : 0; }
    private static String text(Object value) { return value == null ? "" : String.valueOf(value); }
    @SuppressWarnings("unchecked") private static Map<String, Object> object(Object value) { return value instanceof Map<?, ?> ? (Map<String, Object>) value : Map.of(); }
}
