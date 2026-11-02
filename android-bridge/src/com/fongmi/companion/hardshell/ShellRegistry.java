package com.fongmi.companion.hardshell;

import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 加固壳形态注册表。**这是"新增源不改代码"的落点。**
 *
 * <h3>三级来源，后者覆盖前者</h3>
 * <ol>
 *   <li>{@link #builtin()} —— 编译期内置条目（随版本走，保底可用）。</li>
 *   <li>jar 内 {@code assets/hardshell.properties} —— 内置条目的数据化版本，改数据不改代码。</li>
 *   <li>运行期目录 {@code <jars cache>/hardshell/*.properties} —— 现场加源，仅需投放一个文件，
 *       重启即生效，连重新打包都不必。</li>
 * </ol>
 *
 * <h3>为什么这样就能通用</h3>
 * 判定与解包所需的一切（特征条目、索引地址、so 名、入口类、模拟参数）都是数据，
 * 调用方 {@link HardshellPipeline} 只按注册表遍历，不认识任何具体源。
 */
public final class ShellRegistry {

    private static final CopyOnWriteArrayList<ShellProfile> PROFILES = new CopyOnWriteArrayList<>();
    private static volatile boolean loaded;
    /** 已经装载过的运行期目录，避免重复装载或漏装。 */
    private static volatile File loadedDir;

    private ShellRegistry() {
    }

    /**
     * 内置条目。
     *
     * <p>aowu 是首个用本框架接入的源，它的字段全部来自实测（见 REPORT.md），
     * 不含任何特判分支——同族的新源照抄这份数据改字符即可。
     */
    private static List<ShellProfile> builtin() {
        List<ShellProfile> out = new ArrayList<>();
        out.add(new ShellProfile.Builder()
                .id("aowu")
                .displayName("aowu 加固壳")
                // 容器：只有 classes.dex + 一个加密资源
                .shellMarkers("assets/woshinidie.bin")
                // 解密载荷：native 解完会带这两个 so 之一
                .payloadMarkers("assets/awenc-v8.so", "assets/awenc-v7.so")
                // 索引地址留空 → 由 dex 字面量 + 资产名自动发现；
                // 下面两个是实测已知的主/备源，写死可省一次发现，且容错更稳。
                .indexUrls("https://9763.kstore.vip/woshinidie",
                        "http://xn--nsr30bl8nb2kyt7a8vs.top/files/woshinidie")
                .soNames("awdm-v8.so", "awdm-v7.so")
                // 该载荷特有的 dex2jar 坍塌（构造器归属/补帧），由修补链按 id 分派
                .repairIds("ctor-inline")
                .payloadEntry("aowunnn.amns")
                .decryptedName("awdatabase.db")
                .guestBase("/data/local/tmp/aowu")
                .packageName("com.fongmi.android.tv")
                .nativeClass("com.github.catvod.spider.DexNative")
                .unwrapSignature("getLoader(Ljava/lang/Object;Ljava/io/InputStream;)Ljava/lang/Object;")
                // 载荷 MyCrypto 的 22 个 native 由 awenc 注册；awdm 解壳时 setenv 的变量缺失，
                // awenc 的 JNI_OnLoad 会直接 exit_group（实测，见 REPORT 第七轮）。
                // 载荷真正的初始化入口；不调用则 AwInit.context() 为 null，约 50 站在 <clinit> 连坐失败
                .payloadInit("com.github.catvod.spider.AwInit")
                .cryptoSo("assets/awenc-v8.so")
                .cryptoClass("com.github.catvod.spider.MyCrypto")
                .cryptoEnv("wcnmwcnm=aowushinidie")
                .build());
        return out;
    }

    /** 当前全部条目（保证内置条目已就绪）。 */
    public static List<ShellProfile> all() {
        ensureLoaded(null);
        return new ArrayList<>(PROFILES);
    }

    /** 运行期追加一条（后加的优先级高：先匹配到就先用）。 */
    public static void register(ShellProfile profile) {
        if (profile == null) return;
        ensureLoaded(null);
        PROFILES.add(0, profile);
    }

    /**
     * 首次调用时装载：内置 → jar 内 assets → 运行期目录。
     *
     * <p>可有多次调用：先以 {@code null} 初始化（只装内置），后续带上 cacheDir 时
     * 会补装该目录下的外部形态，不会因为「先调用的没给目录」而永久漏装。
     *
     * @param cacheDir jars 缓存目录；可为 null（此时只看内置与 jar 内 assets）
     */
    public static void ensureLoaded(File cacheDir) {
        File dir = profilesDir(cacheDir);
        if (loaded && (dir == null || dir.equals(loadedDir))) return;
        synchronized (ShellRegistry.class) {
            if (!loaded) {
                for (ShellProfile p : builtin()) PROFILES.add(p);
                loadBundled();
                loaded = true;
                System.out.println("[Hardshell] 内置壳形态 " + PROFILES.size() + " 个: " + PROFILES);
            }
            if (dir != null && !dir.equals(loadedDir)) {
                loadFromDir(dir);
                loadedDir = dir;
                System.out.println("[Hardshell] 现有壳形态 " + PROFILES.size() + " 个: " + PROFILES);
            }
        }
    }

    /** 运行期 profile 目录：系统属性优先，其次 jars 缓存下的 hardshell/。 */
    public static File profilesDir(File cacheDir) {
        String override = System.getProperty("xiugou.hardshell.profiles");
        if (!JarIndex.isEmpty(override)) return new File(override.trim());
        return cacheDir == null ? null : new File(cacheDir, "hardshell");
    }

    /**
     * 从目录里的 {@code *.properties} 装载一条或多条 profile。
     * 单个文件解析失败只跳过该文件，不影响其它源。
     *
     * @return 成功装载的条数
     */
    public static int loadFromDir(File dir) {
        if (dir == null || !dir.isDirectory()) return 0;
        File[] files = dir.listFiles((d, n) -> n.toLowerCase().endsWith(".properties"));
        if (files == null) return 0;
        int count = 0;
        for (File f : files) {
            try (InputStream in = Files.newInputStream(f.toPath())) {
                Properties p = new Properties();
                p.load(new InputStreamReader(in, StandardCharsets.UTF_8));
                String fallbackId = f.getName().substring(0, f.getName().length() - ".properties".length());
                ShellProfile profile = ShellProfile.from(p, fallbackId);
                if (profile.shellMarkers.length == 0) {
                    System.err.println("[Hardshell] 跳过 " + f.getName() + "：缺 shell.markers");
                    continue;
                }
                PROFILES.add(0, profile);
                count++;
                System.out.println("[Hardshell] 外部形态已装载: " + profile + " ← " + f.getName());
            } catch (Throwable t) {
                System.err.println("[Hardshell] 形态文件不可用 " + f.getName() + ": " + t.getMessage());
            }
        }
        return count;
    }

    /** jar 内自带的数据化条目（由打包方投放，跟随版本）。 */
    private static void loadBundled() {
        try (InputStream in = ShellRegistry.class.getResourceAsStream("/assets/hardshell.properties")) {
            if (in == null) return;
            Properties p = new Properties();
            p.load(new InputStreamReader(in, StandardCharsets.UTF_8));
            for (String key : p.stringPropertyNames()) {
                if (!key.startsWith("profile.")) continue;
                String suffix = key.substring("profile.".length());
                Properties one = new Properties();
                for (String k : p.stringPropertyNames()) {
                    String prefix = "profile." + suffix + ".";
                    if (k.startsWith(prefix)) one.put(k.substring(prefix.length()), p.getProperty(k));
                }
                ShellProfile profile = ShellProfile.from(one, suffix);
                if (profile.shellMarkers.length > 0) PROFILES.add(0, profile);
            }
        } catch (Throwable ignored) {
        }
    }

    // ------------------------------------------------------------------ 匹配

    /** 该 jar 是不是任一已知壳的容器；命中返回对应 profile，否则 null。 */
    public static ShellProfile matchShell(File jar) {
        if (jar == null || !jar.isFile() || jar.length() == 0) return null;
        for (ShellProfile p : all()) {
            if (p.shellMarkers.length > 0 && p.isShell(jar)) return p;
        }
        return null;
    }

    /** 该 jar 是不是任一已知壳的解密载荷；命中返回对应 profile，否则 null。 */
    public static ShellProfile matchPayload(File jar) {
        if (jar == null || !jar.isFile() || jar.length() == 0) return null;
        for (ShellProfile p : all()) {
            if (p.payloadMarkers.length > 0 && p.isPayload(jar)) return p;
        }
        return null;
    }

    /** 按 id 找形态（子进程与缓存命名用）。 */
    public static ShellProfile byId(String id) {
        if (JarIndex.isEmpty(id)) return null;
        for (ShellProfile p : all()) {
            if (p.id.equalsIgnoreCase(id.trim())) return p;
        }
        return null;
    }

    /** 测试/热更新用：清空已装载状态。 */
    static void resetForTest() {
        PROFILES.clear();
        loaded = false;
    }
}
