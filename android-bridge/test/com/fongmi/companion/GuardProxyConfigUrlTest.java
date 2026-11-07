package com.fongmi.companion;

/** Standalone regression test for issue #6 config-center URL rewrite: run with assertions enabled (-ea). */
public final class GuardProxyConfigUrlTest {
    public static void main(String[] args) {
        rewritesLanConfigCenterToLocalProxy();
        keepsTextWithoutValidPort();
        ignoresOtherPortsAndPaths();
        System.out.println("GuardProxyConfigUrlTest OK");
    }

    private static final String LOCAL = "http://127.0.0.1:9978/proxy?do=pan&action=config";

    private static void rewritesLanConfigCenterToLocalProxy() {
        String text = "如果弹窗没有显示，请打开网页版配置中心：http://192.168.177.1:19989/config";
        String out = GuardProxyServer.rewriteConfigCenterUrls(text, 9978);
        assert ("如果弹窗没有显示，请打开网页版配置中心：" + LOCAL).equals(out) : out;

        String json = "{\"vod_content\":\"打开 http://localhost:19988/config 或 http://10.0.0.2:19997/config。\"}";
        out = GuardProxyServer.rewriteConfigCenterUrls(json, 9978);
        assert ("{\"vod_content\":\"打开 " + LOCAL + " 或 " + LOCAL + "。\"}").equals(out) : out;
    }

    private static void keepsTextWithoutValidPort() {
        String text = "http://192.168.3.60:19988/config";
        assert text.equals(GuardProxyServer.rewriteConfigCenterUrls(text, -1));
        assert GuardProxyServer.rewriteConfigCenterUrls(null, 9978) == null;
    }

    private static void ignoresOtherPortsAndPaths() {
        for (String text : new String[] {
                "http://192.168.3.60:19998/config",
                "http://192.168.3.60:1998/config",
                "http://192.168.3.60:19988/configx",
                "http://192.168.3.60:19988/config/upload",
                "http://192.168.3.60:19988/upload",
                "https://example.com:19988/config",
        }) {
            String out = GuardProxyServer.rewriteConfigCenterUrls(text, 9978);
            assert text.equals(out) : text + " -> " + out;
        }
    }
}
