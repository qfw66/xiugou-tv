package com.fongmi.bridge;

import com.fongmi.companion.SpiderServer;

import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;
import java.security.Provider;
import java.security.Security;
import java.util.ArrayList;
import java.util.List;

/**
 * Android 爬虫 → 桌面 JVM 运行时的唯一对外入口。
 *
 * <p>本类刻意保持"薄"：只收口「装运行时 → 起服务 → 停服务」三件事，
 * 不复制 {@code SpiderServer} / {@code DexSpiderLoader} 里的任何调用分支。
 * 一旦门面里长出第二套 method/参数映射逻辑，它迟早会和真身跑偏，
 * 因此高级用法请直接取 {@link #server()} 或自行 new {@code DexSpiderLoader}。
 *
 * <h3>最小接入</h3>
 * <pre>
 *   AndroidBridge.install();                 // 装 JCE/填充等运行时补丁（幂等）
 *   int port = AndroidBridge.serve(0);       // 0 = 由系统分配端口
 *   System.out.println("[READY] PORT=" + port);
 *   Runtime.getRuntime().addShutdownHook(new Thread(AndroidBridge::shutdown));
 * </pre>
 *
 * <h3>分层（详见 android-bridge/README.md）</h3>
 * <pre>
 *   L1 runtime  android.* shim + AOSP org.json      ← 让 Android 字节码能跑
 *   L2 crawler  com.github.catvod.* 契约与内置实现   ← 载荷依赖的父类/工具
 *   L3 host     DexSpiderLoader / Guard* / SpiderServer ← 加载加固载荷并暴露 RPC
 *   L4 facade   AndroidBridge                          ← 你在这里
 * </pre>
 *
 * @see com.fongmi.companion.DexSpiderLoader
 * @see com.fongmi.companion.SpiderServer
 */
public final class AndroidBridge {

    /** 桥接层版本。语义变更时同步 android-bridge/README.md 的兼容性表。 */
    public static final String VERSION = "1.0.0";

    private static final Object LOCK = new Object();
    private static volatile boolean installed;
    private static SpiderServer server;
    private static volatile int boundPort = -1;

    private AndroidBridge() {
    }

    /**
     * 安装 Android 运行时补丁，可重复调用。
     *
     * <p>当前只做一件事：以最高优先级注册 BouncyCastle Provider，让加解密行为对齐 Android
     * （{@code AES/CBC/PKCS7Padding} 等 Android 专有写法、RSA 块大小与默认填充等语义差异）。
     *
     * <p>注意：这里**不用**本仓库里那个自研的 {@code Pkcs7Provider}——
     * 未签名的 JCE Provider 在现代 JDK 上会被直接拒绝
     * （{@code SecurityException: JCE cannot authenticate the provider}），
     * 所以必须走 BouncyCastle 官方签名 jar。
     */
    public static void install() {
        if (installed) {
            return;
        }
        synchronized (LOCK) {
            if (installed) {
                return;
            }
            registerPkcs7Provider();
            installed = true;
        }
    }

    /**
     * 启动 HTTP RPC 服务（{@code POST /spider/call}）。
     *
     * @param port 监听端口；传 0 表示由系统分配一个空闲端口
     * @return 实际绑定的端口
     */
    public static int serve(int port) throws java.io.IOException {
        install();
        synchronized (LOCK) {
            if (server != null) {
                throw new IllegalStateException("bridge already serving on port " + boundPort);
            }
            server = new SpiderServer(port);
            boundPort = server.start();
            return boundPort;
        }
    }

    /** 当前正在运行的服务；未启动时为 {@code null}。 */
    public static SpiderServer server() {
        return server;
    }

    /** 正在监听的端口；未启动时为 -1。 */
    public static int port() {
        return boundPort;
    }

    /** 停止服务并释放端口；可重复调用。 */
    public static void shutdown() {
        synchronized (LOCK) {
            if (server == null) {
                return;
            }
            try {
                server.stop();
            } finally {
                server = null;
                boundPort = -1;
            }
        }
    }

    /**
     * 在 JVM 上定位并注册 BouncyCastle。
     *
     * <p>查找顺序覆盖四种部署形态：jar 同目录、{@code libs/} 子目录、
     * 相对工作目录的 {@code companion/libs/}、以及用户家目录缓存。
     * 逻辑与迁移前 {@code com.fongmi.companion.Main} 中的实现逐行一致，
     * 日志前缀 {@code [COMPANION_PKCS7]} 保持不变（有外部脚本依赖它）。
     */
    private static void registerPkcs7Provider() {
        String jarName = "bcprov-jdk18on-1.78.1.jar";
        List<File> candidates = new ArrayList<>();
        try {
            File code = new File(AndroidBridge.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
            if (code.isFile()) {
                code = code.getParentFile();
            }
            candidates.add(new File(code, jarName));
            candidates.add(new File(new File(code, "libs"), jarName));
        } catch (Throwable ignored) {
        }
        candidates.add(new File("companion/libs/" + jarName));
        candidates.add(new File("libs/" + jarName));
        candidates.add(new File(new File(
                System.getProperty("user.home", "."), ".xiugou_tv_companion/libs"), jarName));

        for (File f : candidates) {
            try {
                if (!f.isFile() || f.length() == 0) {
                    continue;
                }
                URLClassLoader cl = new URLClassLoader(
                        new URL[]{f.toURI().toURL()}, ClassLoader.getSystemClassLoader());
                Class<?> bcp = cl.loadClass("org.bouncycastle.jce.provider.BouncyCastleProvider");
                Provider p = (Provider) bcp.getDeclaredConstructor().newInstance();
                // 放在最高优先级：载荷按 Android（Conscrypt / BC）语义写加解密，与 JDK 的 SunJCE 有差异，
                // 例如 RSA 解密时 Cipher.getBlockSize() 在 Android 返回模长、SunJCE 返回 0
                // （按块循环 doFinal 的载荷在 SunJCE 下第一块就 BadPaddingException），
                // 以及 "RSA" 不带填充时 Android 默认 NoPadding、SunJCE 默认 PKCS1Padding。
                Security.insertProviderAt(p, 1);
                System.out.println("[COMPANION_PKCS7] BouncyCastle registered from " + f);
                return;
            } catch (Throwable t) {
                System.err.println("[COMPANION_PKCS7] load failed from " + f + ": " + t.getMessage());
            }
        }
        System.err.println("[COMPANION_PKCS7] bcprov jar not found; AES/CBC/PKCS7Padding may fail");
    }
}
