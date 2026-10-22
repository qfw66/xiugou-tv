package com.fongmi.companion;

import com.fongmi.companion.guard.GuardCryptoService;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 加固壳宿主桥（ftyguard native 方法的 Java 近似实现）。
 *
 * ftyguard 载荷通过 InitOrigin.i（宿主 Class）+ 反射调用以下静态方法：
 *   encrypt(String) -> String
 *   decrypt(String) -> String
 *   native_ting_md5(String) -> String
 *   calcResult(int[]) -> int[]
 * 手机端由壳的 native 实现（libftyguard.so RegisterNatives 注册到壳 DexNative）。
 * 桌面端没有该 so，这里提供 Java 实现：
 *   - decrypt: 优先查"离线解密映射表"（~/.xiugou_tv_companion/guard-ext-map.txt，
 *     由 unidbg 加载 libftyguard.so 对 official.json 中各站点 ext 密文离线解密生成；
 *     见 test/repro/unidbg-work-fty/_ext_map_backup.txt），未命中返回原值；
 *   - native_ting_md5: 标准 MD5 十六进制（小写）；
 *   - encrypt/calcResult: 恒等（精确算法待后续从 so 逆向）。
 */
public class GuardHost {

    /** 密文 -> 明文 映射（键为官方 json 中的 ext 密文）。 */
    private static final Map<String, String> EXT_MAP = new ConcurrentHashMap<>();

    /**
     * 内置的 ext 密文 -> 明文表，由 unidbg 加载 libftyguard.so 离线解密得到
     * （test/repro/unidbg-work-fty + _guard_ext.txt）。放在 jar 里做兜底，
     * 否则换机器 / 清掉用户目录后，所有带加密 ext 的站点会集体变成 0 数据，
     * 且因为解密未命中是"静默返回原密文"，日志里看不到任何异常。
     * 用户目录的 guard-ext-map.txt 仍然优先，可覆盖或追加这里没有的条目。
     */
    private static final String[][] BUILTIN_EXT = {
            // csp_SeedhubGuard
            {"5++kwLhNYm9UrO9wh7Dl7eKamTee4s/5", "56We56eY55qE5ZOl5ZOl5Lus"},
            // csp_T4Guard · 光影（wsyzy 采集接口）
            {"rfOIzPkSUkANv6AT2prC8en3+Trbx4j10CIoZMv3Ag4bdEYQqTMqu/Z3YPtC2NJv6n6YeZdgyWlo4WJjBL5gUt6B7LvCEDT4CLrWka31GRq7jwVkfQRB/Jy9HkG7E8xUBIJi5DdVFk3qAuGnwUWqQNRblRxzHW+tdSm6zoFcG/QkZ97bzWOXn0fzbgwjBDkBHgcPIYjlULlctCNKgJ9DzGNSl+zMZDZgmxczsZeeahRS38Cst3qvaHn1T2lmLBGVGXPaRovi77LPRRDOJSNRrdpvCHdRikYwgar0MU56hXMGeGBiKp/OmGTIYR8dFRGvZ/m8xGOqs8U13h6wvADOGlYoP9VaQBqTcDnz9Q0Urhw3oFXWyvIlUrDhX9la5L2NYzagbyk3afqhxeSXXp07nAFsNy2CojHRTbmz4eohLoIJTSi2DzPpheVx1DAapfgRdTc7Ax5ddYpN338GiDAa0GnEgLe04a1pZ5jF+/Q7HJswqlSO+DXCQ3FjRbb/ZPQcozcCWwzhUHE1QUAt799V9DPMuiHGyudIcZarGQmezB+Lb45RdHIRy0PXD+NRVPJlfDFD5FMGSqsiVklibvuwlVHT8J5vHgh/1nEZoI1RlYYLrkjTts2EeQmrpB/sgLyo1vnjFw==",
                    "{\"siteUrl\":\"http://api.wsyzy.net/api.php/provide/vod/?ac=list\",\"type\":1,\"searchMode\":\"web&https://api.wsyzy.net/\",\"categories\":[\"动作片\",\"喜剧片\",\"科幻片\",\"恐怖片\",\"战争片\",\"国产剧\",\"欧美剧\",\"韩剧\",\"日剧\",\"港剧\",\"台剧\",\"泰剧\",\"纪录片\",\"大陆综艺\",\"日韩综艺\",\"港台综艺\",\"欧美综艺\",\"国产动漫\",\"日韩动漫\",\"欧美动漫\",\"欧美动漫\",\"动画片\",\"演唱会\",\"爽文短剧\",\"4K电影\",\"漫剧\",\"Netflix电影\",\"Netflix自制剧\"]}"},
            // csp_AppTTGuard · 热播
            {"uqGL1bNENExT7/hGxpSE5qU=", "http://v.rbotv.cn"},
            // csp_App99Guard · 视界（剧圈圈 App）
            {"rfOX1voDIQhH8epBwtCFsuby/mmdmIu8kGlnJc+7VkMRLQ1K+jMy+KN1MKQe0MZ6tmGSO5oFzD8/vWwiSqEpFczDqLrdGT3iH6fZmryrFzKijwYkJUMctdztE0O4CsgYZdBu8XhZSwuhSqqllQz4AZMa1l0sT+1NrbhNIxHkrY0upiYSTLNqEaledgZikMCviOXWr3cPBP4COOeoGUyJSJrrybmUppnWGeDAOHhHOVUSXjwSb+QQvcJIT2lmrf1Bk68myGs7qOqc19tD/rnzf2WOb2MzJZqtURBmUFgaW6ea2dL8OPSpSeVAvaGCAnqwuUNGE9hHpK8jfOs0bLJRdkFLnijAn5Q+ofVM5hgGb8c=",
                    "{\"host\":\"http://124.221.3.182:19987/app/bn\",\"appkey\":\"d1f0c269eab74d93821fffc9befdbbba\",\"versionName\":\"1.2.0\",\"name\":\"剧圈圈\",\"package\":\"com.qingtangxiaozhuan.xyz\",\"buildNumber\":\"2002\",\"buildSignature\":\"054FA8DDA4319C6B6A9B954CA5777541C993F00B1B0BD4394F7EDE48184C4594\"}"},
            // csp_AppSxGuard · 剧圈
            {"rfOX1voDIQhH8epBwpmIsuSluiuZl4+/lm1iJsy3HwNWMxpf9CY77fshI+kByoxy7DyPatUZ1jk0ty1p",
                    "{\"host\":\"https://app.95112475.xyz\",\"key\":\"5a9w6x58dsq6z3a6\"}"},
            // csp_T4Guard · 奶酪（dyttzy 采集接口）
            {"rfOIzPkSUkANv6AT2prC8en3+TzKx9TnlT8vaY37HhtYfAQe6C5xqrVuJPhQwYV6r3eRdMBGm3Qm6Th+BushR86B6KqJGXDsHazHw7alBG/7zUxkN1tK/NypRxnpBNoeUtpw4jcCGhytI75yO4g4zG6SOPA0RSwhksM0IF2friAkrHCWoW3v+0mdw6sjz4t4XB1Df7yL/R5cfaA/5LQYq3I8OkvMrJMU9Q1P7JXwx7NSF2zTyH/ANVmZ4u5m567DW1KVG7OuQjXPjZiOXTYk0+wjpfBRTf19yIq6q/C76k2Fs80joAMPw0ueDR+QHxtuDcTom2rmHkI1Fonkzi6BotbpUcbSi4PiIgmfdbvVwhG6Z+i4nvt+IYa48l5aLA7PLgDiERpuOs31aHaXlgFswT87XyTb8QaF4CuzKWJuXptwNTjvXAS9KHdxH49Ay+hfBAB2bCvUf4CMoldF2wZUv0mI2qY966erFpOFg+FOc7t88EUH8j8ACXQtHJiKC9RQ+SaLIF0=",
                    "{\"siteUrl\":\"http://caiji.dyttzyapi.com/api.php/provide/vod/from/dyttm3u8/at/m3u8/\",\"type\":1,\"categories\":[\"动作片\",\"喜剧片\",\"爱情片\",\"科幻片\",\"恐怖片\",\"战争片\",\"国产剧\",\"香港剧\",\"韩国剧\",\"欧美剧\",\"记录片\",\"台湾剧\",\"日本剧\",\"海外剧\",\"泰国剧\",\"大陆综艺\",\"港台综艺\",\"日韩综艺\",\"动画片\",\"国产动漫\",\"日韩动漫\",\"欧美动漫\"]}"},
            // csp_AppSxGuard · 咕咕（站点当前 Cloudflare 526，映射仍保留以便源站恢复）
            {"rfOX1voDIQhH8epBwpmIsuS/sSCZxc/l0mxkeoroQVYOelMAvX1kuYptSLB36YxEjVawS9p37Cgo",
                    "{\"host\":\"https://www.gugu3.com\",\"key\":\"nKfZ8KX6JTNWRzTD\"}"},
            // csp_AllliveGuard · 一直播
            {"uqGL1fpJNAUN8ORQgIPD+b6l+CzC2t8=", "https://live.muxia.site"},
    };

    static {
        for (String[] entry : BUILTIN_EXT) {
            EXT_MAP.put(entry[0], entry[1]);
        }
        loadExtMap();
    }

    private static void loadExtMap() {
        try {
            java.io.File f = new java.io.File(
                    new java.io.File(System.getProperty("user.home", "."), ".xiugou_tv_companion"),
                    "guard-ext-map.txt");
            if (!f.isFile()) {
                return;
            }
            for (String line : java.nio.file.Files.readAllLines(f.toPath(), StandardCharsets.UTF_8)) {
                int p = line.indexOf('\t');
                if (p > 0) {
                    EXT_MAP.put(line.substring(0, p), line.substring(p + 1));
                }
            }
            System.out.println("[GuardHost] loaded " + EXT_MAP.size() + " ext decrypt mappings");
        } catch (Throwable t) {
            System.err.println("[GuardHost] ext map load failed: " + t);
        }
    }

    public static String encrypt(String s) {
        if (s == null) {
            return null;
        }
        // 手机端 encrypt 由壳 so 实现；桌面端优先问常驻服务，不可用时退回恒等。
        String viaShell = GuardCryptoService.encrypt(s);
        return viaShell != null ? viaShell : s;
    }

    public static String decrypt(String s) {
        if (s == null) {
            return null;
        }
        String mapped = EXT_MAP.get(s);
        // -Dxiugou.guard.crypto=service 时优先问壳，用来核对「so 结果 vs 离线表」是否一致。
        if ("service".equals(GuardCryptoService.mode())) {
            String viaShell = GuardCryptoService.decrypt(s);
            if (viaShell != null) {
                return viaShell;
            }
            return mapped != null ? mapped : s;
        }
        // 默认 auto：表里有的直接返回（零成本），表里没有的才启动壳服务现解。
        if (mapped != null) {
            return mapped;
        }
        String viaShell = GuardCryptoService.decrypt(s);
        return viaShell != null ? viaShell : s;
    }

    /**
     * 载荷并不是按名字 decrypt 来找宿主解密，而是拿它自己混淆过的名字反射问
     * InitOrigin.i（即本类）要方法：反编译载荷 g8.KJ 可见
     * {@code InitOrigin.i.getDeclaredMethod(<7 个 U+0AB5>, String.class).invoke(null, s)}，
     * 失败则 catch 掉并返回空串。名字对不上时，带加密 ext 的站点就表现为
     * 「homeContent 有分类、categoryContent 0 部」，日志里只有一条 NoSuchMethodException。
     *
     * 方法名是载荷自带的混淆名，只能用同名字符串对齐；语义就是本类的 decrypt。
     * 用 \u0AB5 转义书写，避免源码编码在不同机器上把标识符弄坏。
     */
    @SuppressWarnings("checkstyle:MethodName")
    public static String \u0AB5\u0AB5\u0AB5\u0AB5\u0AB5\u0AB5\u0AB5(String s) {
        return decrypt(s);
    }

    public static String native_ting_md5(String s) {
        if (s == null) {
            return null;
        }
        // 壳里的 native_ting_md5 不是标准 MD5（实测 "hello" -> 01def1de…），
        // 优先用 so 的真实实现；服务不可用时才退回标准 MD5 近似。
        String viaShell = GuardCryptoService.tingMd5(s);
        if (viaShell != null) {
            return viaShell;
        }
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] d = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) {
                sb.append(String.format("%02x", b & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return s;
        }
    }

    public static int[] calcResult(int[] arr) {
        // 原始实现是 so 里的位运算，Java 恒等只是占位；能问到壳就用真值。
        int[] viaShell = GuardCryptoService.calcResult(arr);
        return viaShell != null ? viaShell : arr;
    }
}
