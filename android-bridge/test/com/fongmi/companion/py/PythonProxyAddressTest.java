package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

/** Live JSON normalization through a real Python child; all inputs are synthetic. */
public final class PythonProxyAddressTest {
    private static final String SITE = "YSP + 中文";
    private static final String BASE = "http://127.0.0.1:19991/script-proxy";
    private static final String NESTED = "https://media.invalid/a.ts?token=a%2Bb&next=%252F&x=中";
    private static final String SCRIPT = """
            import os
            from urllib.parse import urlencode
            class Spider:
                def init(self, ext=''): pass
                def liveContent(self, mode):
                    base = os.environ['XIUGOU_SCRIPT_PROXY_BASE']
                    token = base.split('?token=', 1)[1]
                    params = {'token': token, 'do': 'py', 'siteKey': os.environ['XIUGOU_SCRIPT_SITE_KEY'],
                              'type': 'app', 'url': 'https://media.invalid/a.ts?token=a%2Bb&next=%252F&x=中'}
                    if mode in ('token', 'do', 'siteKey'): params[mode] = 'wrong'
                    pseudo = 'proxy://' + urlencode(params)
                    if mode == 'duplicate': pseudo += '&type=other'
                    if mode == 'malformed': pseudo += '&bad=%ZZ'
                    if mode == 'question': pseudo = pseudo.replace('proxy://', 'proxy://?', 1)
                    if mode == 'normal':
                        return [{'name': 'proxy://name-must-stay', 'channel': [
                            {'name': 'test', 'urls': [pseudo + '$App高清', 'https://media.invalid/plain$原址',
                                                   pseudo.replace('type=app', 'type=tv') + '$电视'],
                             'epg': 'proxy://epg-must-stay', 'nested': {'url': pseudo + '$nested'}},
                            {'name': 'old', 'url': base + '&do=py&siteKey=old&id=cctv1'}]}]
                    if mode == 'local': return {'local': os.environ.get('XIUGOU_LOCAL_DIR'),
                                                'site': os.environ.get('XIUGOU_SCRIPT_SITE_KEY')}
                    return [{'channel': [{'url': pseudo}]}]
            """;

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("xiugou-proxy-address-").toRealPath();
        String previousHome = System.getProperty("user.home");
        PySpider spider = null;
        List<String> failures = new ArrayList<>();
        try {
            Path home = Files.createDirectories(root.resolve("home"));
            System.setProperty("user.home", home.toString());
            Path source = root.resolve("source.py");
            Files.writeString(source, SCRIPT, StandardCharsets.UTF_8);
            spider = new PySpider(source.toString(), "", root.toFile(), SITE, BASE);
            spider.init(null, "");
            try {
                List<?> groups = (List<?>) JsonCodec.parse(spider.liveContent("normal"));
                Map<?, ?> group = (Map<?, ?>) groups.get(0);
                check("proxy://name-must-stay".equals(group.get("name")), "non URL fields must not be normalized");
                List<?> channels = (List<?>) group.get("channel");
                Map<?, ?> first = (Map<?, ?>) channels.get(0);
                List<?> urls = (List<?>) first.get("urls");
                check(urls.size() == 3, "ordered urls must retain all entries");
                verify((String) urls.get(0), "App高清", "app", spider.proxyToken());
                check("https://media.invalid/plain$原址".equals(urls.get(1)), "ordinary HTTP URL must stay unchanged");
                verify((String) urls.get(2), "电视", "tv", spider.proxyToken());
                verify((String) ((Map<?, ?>) first.get("nested")).get("url"), "nested", "app", spider.proxyToken());
                check("proxy://epg-must-stay".equals(first.get("epg")), "normalization is restricted to url/urls fields");
                check((BASE + "?token=" + spider.proxyToken() + "&do=py&siteKey=old&id=cctv1")
                        .equals(((Map<?, ?>) channels.get(1)).get("url")), "old single HTTP URL must stay unchanged");
                System.out.println("PASS ordered proxy URLs, labels, nested query and existing HTTP fields");
            } catch (Exception | AssertionError error) { failures.add("normal: " + error); }
            for (String mode : List.of("token", "do", "siteKey", "duplicate", "malformed", "question")) {
                try {
                    spider.liveContent(mode);
                    failures.add(mode + ": malformed/conflicting pseudo URL must be rejected");
                } catch (IllegalArgumentException expected) {
                    System.out.println("PASS rejects " + mode);
                }
            }
            try {
                Map<String, Object> local = JsonCodec.parseObject(spider.liveContent("local"));
                check(home.resolve(".xiugou_tv_companion/py-local").toString().equals(local.get("local")),
                        "host must inject site-local directory from isolated user.home");
                check(SITE.equals(local.get("site")), "site identity must remain independent from script path");
                System.out.println("PASS Local directory and site environment");
            } catch (Exception | AssertionError error) { failures.add("local: " + error); }
            check(failures.isEmpty(), String.join("\n", failures));
            System.out.println("PythonProxyAddressTest OK (8 real Python address/env boundaries)");
        } finally {
            if (spider != null) spider.destroy();
            if (previousHome == null) System.clearProperty("user.home");
            else System.setProperty("user.home", previousHome);
            check(root.isAbsolute() && root.getFileName().toString().startsWith("xiugou-proxy-address-"), "verify generated cleanup root");
            try (Stream<Path> files = Files.walk(root)) {
                for (Path file : (Iterable<Path>) files.sorted(Comparator.reverseOrder())::iterator) Files.deleteIfExists(file);
            }
        }
    }

    private static void verify(String value, String label, String type, String token) {
        check(value.endsWith("$" + label), "display label must remain unchanged");
        URI uri = URI.create(value.substring(0, value.indexOf('$')));
        check((uri.getScheme() + "://" + uri.getAuthority() + uri.getPath()).equals(BASE), "pseudo URL must bind to registered HTTP route");
        Map<String, String> params = new LinkedHashMap<>();
        for (String pair : uri.getRawQuery().split("&")) {
            String[] parts = pair.split("=", 2);
            String key = URLDecoder.decode(parts[0], StandardCharsets.UTF_8);
            check(params.putIfAbsent(key, URLDecoder.decode(parts[1], StandardCharsets.UTF_8)) == null, "no duplicate route keys");
        }
        check(params.equals(Map.of("token", token, "do", "py", "siteKey", SITE, "type", type, "url", NESTED)),
                "nested URLs must decode exactly once with original token and site");
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
