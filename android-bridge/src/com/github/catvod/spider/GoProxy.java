package com.github.catvod.spider;

/**
 * 载荷 {@code com.github.catvod.spider.GoProxy} 的桌面替身。
 *
 * <p>原类在静态块里 {@code System.load} ARM64 的 {@code libwexproxy.so}，再由 native
 * {@link #startServer} 在 127.0.0.1:8096 起「多线程加速代理」。Windows 无法加载该 so，
 * 静态块抛错后每次触碰都是 {@code NoClassDefFoundError}，日志里大量刷屏，且会打断调用它的后台线程。
 *
 * <p>桌面端的等价能力已经由 companion 自己提供：playerContent 返回的 8096 地址被
 * {@code NetdiskProxyUnwrap} 拆壳并改走 {@code NetdiskChunkProxy}（分块并发），
 * 所以这里只需「启动成功、什么也不做」。companion 的载荷 ClassLoader 是父优先，同名即可顶替。
 */
public class GoProxy {

    public GoProxy() {
    }

    /** 原实现清理旧的随机名 so 副本；桌面端没有副本可清。 */
    public static int deleteFilesWithFeature(String dir, String feature) {
        return 0;
    }

    public static void startServer(String a, String port, String b, boolean c, String dns, String url, String d) {
        com.github.catvod.utils.DebugLog.line("Netdisk", "载荷请求启动 8096 加速代理：桌面端由 companion 分块并发代理接管，忽略");
    }
}
