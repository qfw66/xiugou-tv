package android.net;

/** Standalone regression test for issue #11 (quark QR URL with '|'): run with assertions enabled (-ea). */
public final class UriLenientTest {
    public static void main(String[] args) {
        quarkQrUrlKeepsHost();
        payloadLanRewriteLeavesRemoteUrlAlone();
        loopbackStillRewritable();
        lenientAuthorityParts();
        strictUrlsUnchanged();
        System.out.println("UriLenientTest OK");
    }

    private static final String QUARK = "https://su.quark.cn/4_eMHBJ?token=abc&client_id=386"
            + "&sch=pckk@other_ch&sve=3.1.8&ssb=weblogin&uc_param_str="
            + "&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0";

    private static void quarkQrUrlKeepsHost() {
        Uri u = Uri.parse(QUARK);
        assert "https".equals(u.getScheme()) : u.getScheme();
        assert "su.quark.cn".equals(u.getHost()) : u.getHost();
        assert u.getPort() == -1;
        assert "/4_eMHBJ".equals(u.getEncodedPath()) : u.getEncodedPath();
        assert "abc".equals(u.getQueryParameter("token"));
        assert "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0".equals(u.getQueryParameter("uc_biz_str"));
        assert QUARK.equals(u.toString());
    }

    /** 载荷 merge/y0/e.z：host 为空或是本机地址时才换成局域网 IP，否则原样返回。 */
    private static String payloadRewrite(String s, String lanIp) {
        Uri u = Uri.parse(s);
        String host = u.getHost();
        boolean local = host == null || host.isEmpty() || "127.0.0.1".equals(host)
                || "localhost".equalsIgnoreCase(host) || "0.0.0.0".equals(host);
        if (!local) return s;
        String authority = lanIp + (u.getPort() > 0 ? ":" + u.getPort() : "");
        return u.buildUpon().encodedAuthority(authority).build().toString();
    }

    private static void payloadLanRewriteLeavesRemoteUrlAlone() {
        String out = payloadRewrite(QUARK, "192.168.177.1");
        assert QUARK.equals(out) : out;
    }

    private static void loopbackStillRewritable() {
        String out = payloadRewrite("http://127.0.0.1:9978/proxy?do=pan&x=a|b", "192.168.177.1");
        assert "http://192.168.177.1:9978/proxy?do=pan&x=a|b".equals(out) : out;
    }

    private static void lenientAuthorityParts() {
        Uri u = Uri.parse("http://user@[::1]:8080/p%20q?a=1|2#f|g");
        assert "[::1]".equals(u.getHost()) : u.getHost();
        assert u.getPort() == 8080;
        assert "user".equals(u.getUserInfo());
        assert "/p q".equals(u.getPath()) : u.getPath();
        assert "/p%20q".equals(u.getEncodedPath());
        assert "a=1|2".equals(u.getEncodedQuery());
        assert "f|g".equals(u.getFragment());

        Uri plain = Uri.parse("not a uri |");
        assert plain.getScheme() == null;
        assert plain.getHost() == null;
        assert "not a uri |".equals(plain.toString());
    }

    private static void strictUrlsUnchanged() {
        Uri u = Uri.parse("http://example.com:81/a/b?x=1&y=%E4%B8%AD#top");
        assert "example.com".equals(u.getHost());
        assert u.getPort() == 81;
        assert "b".equals(u.getLastPathSegment());
        assert "中".equals(u.getQueryParameter("y"));
        assert "top".equals(u.getFragment());
        assert Uri.parse("").getHost() == null;
        assert Uri.parse(null) == Uri.EMPTY;
    }
}
