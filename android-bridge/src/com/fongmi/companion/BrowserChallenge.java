package com.fongmi.companion;

import org.jsoup.Jsoup;
import java.io.IOException;
import java.net.URI;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

final class BrowserChallenge extends IOException {
    final String id = UUID.randomUUID().toString().replace("-", "");
    final URI url;
    BrowserChallenge(URI url) { super("Site requires manual browser verification"); this.url = httpUrl(url); }
    Map<String,Object> descriptor() { return Map.of("id",id,"url",url.toASCIIString(),"origin",origin(url)); }
    static URI httpUrl(URI url) {
        if (url == null || url.getHost() == null || url.getUserInfo() != null ||
                !("https".equalsIgnoreCase(url.getScheme()) || "http".equalsIgnoreCase(url.getScheme())))
            throw new IllegalArgumentException("Browser verification requires an HTTP(S) URL");
        return url;
    }
    static String origin(URI raw) {
        URI url = httpUrl(raw);
        String host = url.getHost().toLowerCase(Locale.ROOT);
        if (host.contains(":") && !host.startsWith("[")) host = "[" + host + "]";
        String scheme = url.getScheme().toLowerCase(Locale.ROOT);
        int port = url.getPort();
        return scheme + "://" + host + (port < 0 || port == (scheme.equals("https") ? 443 : 80) ? "" : ":" + port);
    }
    static boolean detected(Map<String,Object> response) {
        Object rawHeaders = response.get("headers");
        if (rawHeaders instanceof Map<?,?> headers) {
            for (var entry : headers.entrySet())
                if (String.valueOf(entry.getKey()).equalsIgnoreCase("cf-mitigated") &&
                        String.valueOf(entry.getValue()).equalsIgnoreCase("challenge")) return true;
        }
        String body = String.valueOf(response.getOrDefault("content", ""));
        boolean active = body.contains("window._cf_chl_opt") || body.contains("window['_cf_chl_opt']") || body.contains("window[\"_cf_chl_opt\"]");
        if (active) return true;
        if (!body.contains("cf-chl-") && !body.contains("/cdn-cgi/challenge-platform")) return false;
        var document = Jsoup.parse(body);
        String title = document.title().toLowerCase(Locale.ROOT);
        return (title.contains("just a moment") || title.contains("attention required") || title.contains("verify you are human")) &&
                !document.select("#challenge-running,#challenge-stage,#challenge-form,.cf-challenge,.cf-turnstile").isEmpty();
    }
    static BrowserChallenge find(Throwable error) {
        for (int i=0;error!=null && i<16;i++,error=error.getCause()) if(error instanceof BrowserChallenge challenge) return challenge;
        return null;
    }
}
