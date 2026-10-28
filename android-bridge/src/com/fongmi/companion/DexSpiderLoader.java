package com.fongmi.companion;

import android.content.Context;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;
import com.github.catvod.spider.UnsupportedGuardSpider;
import com.fongmi.companion.d2j.PreciseDex2jar;
import com.fongmi.companion.guard.GuardCryptoService;

import java.io.*;
import java.lang.reflect.Method;
import java.net.URI;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Intelligent Spider Loader for standard JVM companion service.
 * Supports built-in CatVod spiders, intelligent alias normalization, and dynamic jar classloading.
 */
public class DexSpiderLoader {

    private final ConcurrentHashMap<String, ClassLoader> loaders = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Spider> spiders = new ConcurrentHashMap<>();
    /** 载荷内 Spider 子类扫描缓存（按 loader）——类发现兜底用，避免每次调用扫 zip。 */
    private static final Map<ClassLoader, List<String>> SPIDER_CLASSES =
            java.util.Collections.synchronizedMap(new java.util.WeakHashMap<ClassLoader, List<String>>());
    private final File cacheDir;

    private static final Map<String, String> ALIAS_MAP = new HashMap<>();
    static {
        // Bilibili family
        ALIAS_MAP.put("bili", "Bili");
        ALIAS_MAP.put("biliguard", "Bili");
        ALIAS_MAP.put("biliych", "Bili");
        ALIAS_MAP.put("bilibili", "Bili");

        // Kanqiu / Live family
        ALIAS_MAP.put("kanqiu", "Kanqiu");
        ALIAS_MAP.put("kanqiuguard", "Kanqiu");
        ALIAS_MAP.put("livekanqiu", "Kanqiu");

        // Push / Streaming
        ALIAS_MAP.put("push", "Push");
        ALIAS_MAP.put("pushguard", "Push");
        ALIAS_MAP.put("push_agent", "Push");

        // AList / Cloud Drive
        ALIAS_MAP.put("alist", "AList");
        ALIAS_MAP.put("alistguard", "AList");

        // Fy 继承载荷里的 Pan，Pan.init 在 HotSpot 21 上会稳定触发
        // EXCEPTION_ACCESS_VIOLATION（-Xint 纯解释执行同样复现，排除 JIT 误编译）。
        // 但它走的是 Level 0「Guard 站点优先从载荷加载」，比 ALIAS_MAP 更早命中，
        // 所以拦截必须用 BLOCKED_API 在主流程之前完成（见 isBlockedByCrash）。

        // DouDouGuard is an Android-native protected wrapper. It is not Douban.
        // Keep the distinction explicit so the desktop bridge does not fabricate
        // categories while silently returning an empty video list.
        ALIAS_MAP.put("doudouguard", "UnsupportedGuardSpider");
        ALIAS_MAP.put("doudou", "UnsupportedGuardSpider");

        // Nmys / Nuomi family
        ALIAS_MAP.put("nmys", "Nmys");
        ALIAS_MAP.put("nmysguard", "Nmys");
        ALIAS_MAP.put("nmyswv", "Nmys");
        ALIAS_MAP.put("nmyswvguard", "Nmys");
        ALIAS_MAP.put("nuomi", "Nmys");

        // AppYsV2 / CMS Web App family
        ALIAS_MAP.put("appysv2", "AppYsV2");
        ALIAS_MAP.put("appttguard", "AppYsV2");
        ALIAS_MAP.put("app99guard", "AppYsV2");
        ALIAS_MAP.put("appsxguard", "AppYsV2");
        ALIAS_MAP.put("appgzguard", "AppYsV2");
        ALIAS_MAP.put("hmysguard", "AppYsV2");
        ALIAS_MAP.put("newczguard", "AppYsV2");
        ALIAS_MAP.put("bttwooguard", "AppYsV2");
        ALIAS_MAP.put("jpysguard", "AppYsV2");
        ALIAS_MAP.put("ycyzguard", "AppYsV2");
    }

    /**
     * 部分站点在配置源里缺少 ext，而载荷爬虫把 ext 当成 baseUrl 的唯一来源，
     * 空 ext 会让 homeContent 直接返回空串（表现为整站 0 分类 0 视频，且没有任何异常）。
     * 典型：饭太硬配置的 csp_NewCzGuard 没有 ext，实测只返回 {"code":0,"data":""}；
     * 官方 csp_NewCz 条目用的就是这个地址，补上后同一份载荷立刻返回 11 分类 / 57 部。
     * 只对"ext 为空"生效，配置源给了 ext 时不干预。
     */
    private static final Map<String, String> DEFAULT_EXT = new HashMap<>();

    static {
        DEFAULT_EXT.put("NewCzGuard", "https://www.czzy77.com/");
    }

    /**
     * 桌面端必须在加载前拒绝的载荷：它们的 init 会让 HotSpot 直接段错误
     * （EXCEPTION_ACCESS_VIOLATION），而 Java 层捕获不到 SIGSEGV——
     * 放进来一个，整个 companion 连同其它站一起死。
     *
     * 实测：csp_FyGuard → 载荷类 Fy（继承 Pan）→ Pan.init +6 崩，-Xint 同样崩，
     * 去掉 -noverify 也照崩，只在 Windows JDK21 复现。只能不加载。
     */
    private static final java.util.Set<String> BLOCKED_API = new java.util.HashSet<>();

    static {
        BLOCKED_API.add("fyguard");
        BLOCKED_API.add("fy");
    }

    public DexSpiderLoader() {
        String userHome = System.getProperty("user.home", ".");
        this.cacheDir = new File(new File(userHome, ".xiugou_tv_companion"), "jars");
        if (!cacheDir.exists()) {
            cacheDir.mkdirs();
        }
    }

    public File getCacheDir() {
        return cacheDir;
    }

    public void clear() {
        for (Spider spider : spiders.values()) {
            try {
                spider.destroy();
            } catch (Throwable ignored) {}
        }
        loaders.clear();
        spiders.clear();
        // 本地代理持有端口与线程；配置切换后旧 loader 不再使用，必须一并释放
        GuardProxyServer.releaseAll();
        ParseStage.reset();
        SPIDER_CLASSES.clear();
    }

    public Spider getSpider(String siteKey, String api, String ext, String jar) {
        String cleanApi = normalizeApiName(api);
        // 崩溃站必须在 Level 0（载荷加载）之前短路，否则进程直接消失。
        if (BLOCKED_API.contains(cleanApi.toLowerCase(java.util.Locale.ROOT))) {
            System.err.println("[DexSpiderLoader] 已禁用会在本机 JDK 上崩溃的载荷: api=" + api
                    + " site=" + siteKey + "（加载它会触发 SIGSEGV，拖死整个 companion）");
            return new UnsupportedGuardSpider();
        }
        if (ext == null || ext.trim().isEmpty()) {
            String fallback = DEFAULT_EXT.get(cleanApi);
            if (fallback != null) {
                ext = fallback;
            }
        }
        String jarKey = md5(jar != null ? jar : "default");
        String spKey = jarKey + "_" + siteKey + "_" + cleanApi;

        Spider cached = spiders.get(spKey);
        if (cached != null) return cached;

        Spider spider = null;
        try {
            spider = resolveSpiderInstance(siteKey, api, cleanApi, ext, jar);
            if (spider != null) {
                spider.siteKey = siteKey;
                spider.init(Context.get(), ext != null ? ext : "");
                System.out.println("[DexSpiderLoader] Successfully initialized spider: " + cleanApi + " for site: " + siteKey);
                spiders.put(spKey, spider);
                return spider;
            }
        } catch (Throwable t) {
            ParseStage.Failure stage = ParseStage.current();
            System.err.println("[DexSpiderLoader] Error instantiating spider " + cleanApi + ": " + t.getMessage()
                    + (stage != null ? "（阶段=" + stage.stage + "）" : ""));
            t.printStackTrace();
        }
        // 失败结果**不进缓存**：加固载荷可能是首次自动解密（约 10 s）尚未就绪，
        // 或者 jar 还没下载完；一旦把 SpiderNull 缓存住，该站点会一直空白直到进程重启
        // （实测现象：糯米站整页无数据，而其它先访问的站点正常）。
        ParseStage.Failure stage = ParseStage.current();
        System.err.println("[DexSpiderLoader] Fallback to SpiderNull for: " + api + " (site: " + siteKey
                + ", 本次不缓存，下次调用会重试加载)"
                + (stage != null ? "（阶段=" + stage.stage + "，原因=" + stage.detail + "）" : ""));
        return new SpiderNull();
    }

    private Spider resolveSpiderInstance(String siteKey, String api, String cleanApi, String ext, String jar) {
        // JavaScript source adapters arrive in ext as an object containing extra.js.
        if (ext != null && ext.contains("\"js\"")) {
            try {
                return new JavaScriptSpider(api, ext);
            } catch (Throwable t) {
                System.err.println("[DexSpiderLoader] Failed to create JavaScript source adapter: " + t.getMessage());
            }
        }

        // Level 0: 加固(Guard)站点优先从外部 jar（守卫载荷）加载。
        // 必须优先于内置别名（ALIAS_MAP 里 appttguard -> AppYsV2 等兼容映射），
        // 否则 csp_XxxGuard 站点会被内置兼容实现劫持，拿不到载荷里的真实爬虫。
        if (cleanApi.endsWith("Guard") && jar != null && !jar.trim().isEmpty()) {
            Spider fromJar = tryLoadFromJar(siteKey, cleanApi, ext, jar, true);
            if (fromJar != null) {
                return fromJar;
            }
        }

        // Level 0.5: 载荷内「去 Guard 后缀」的类发现。
        //
        // 载荷里的类名不带 Guard 后缀（Bili / Nmyswv / DouDou …），而配置里的 api
        // 是 csp_BiliGuard / csp_DouDouGuard，Level 0 的精确匹配必然落空。若此时
        // 直接落到 Level 1，ALIAS_MAP 会命中 companion 内置的**简化兼容实现**
        // （Bili 只返回硬编码分类 + B 站搜索、DouDou 直接是 UnsupportedGuardSpider），
        // 真正的载荷爬虫永远不会被实例化——实测表现就是首页有分类、点进去列表恒空。
        //
        // 因此类发现必须先于内置别名执行，与 Level 0 的注释保持同一意图。
        if (jar != null && !jar.trim().isEmpty() && !hardStop()) {
            Spider discovered = tryDiscoverFromJar(siteKey, cleanApi, ext, jar);
            if (discovered != null) {
                return discovered;
            }
        }

        // Level 1: Try built-in Spiders in companion classpath
        Class<?> builtinClass = findBuiltinSpiderClass(cleanApi);
        if (builtinClass != null) {
            try {
                Object instance = builtinClass.getDeclaredConstructor().newInstance();
                if (instance instanceof Spider) {
                    return (Spider) instance;
                }
                return new GenericSpiderWrapper(instance, siteKey, ext);
            } catch (Throwable t) {
                System.err.println("[DexSpiderLoader] Failed to create built-in instance for " + cleanApi + ": " + t.getMessage());
            }
        }

        // Level 2: Try loading from external Jar if specified
        if (jar != null && !jar.trim().isEmpty()) {
            // 下载/校验/解密这类「与类名无关」的硬失败，后续尝试必然同样失败：
            // 直接短路，避免一次 getSpider 触发 3 次重复下载。
            if (hardStop()) return null;
            Spider fromJar = tryLoadFromJar(siteKey, cleanApi, ext, jar, false);
            if (fromJar != null) {
                return fromJar;
            }
            if (hardStop()) return null;
            // Level 3: 类发现兜底。精确名（Xxx / XxxGuard / 裸名）全失败时，
            // 扫描载荷内的 Spider 子类；**多候选一律放弃**，绝不「随便挑一个」。
            Spider discovered = tryDiscoverFromJar(siteKey, cleanApi, ext, jar);
            if (discovered != null) {
                return discovered;
            }
        }

        return null;
    }

    /** 已记录「与类名无关」的硬失败阶段时，本次调用不再重试同一 jar。 */
    private boolean hardStop() {
        ParseStage.Failure failure = ParseStage.current();
        if (failure == null) return false;
        return ParseStage.DOWNLOAD.equals(failure.stage)
                || ParseStage.MD5.equals(failure.stage)
                || ParseStage.DECRYPT.equals(failure.stage)
                || ParseStage.RESOLVE.equals(failure.stage);
    }

    /**
     * 从外部 jar（含加固壳解密后的守卫载荷）加载 spider 类并实例化。
     * stripFirst=true 时先按 Guard 后缀映射（csp_XxxGuard -> com.github.catvod.spider.Xxx）。
     */
    private Spider tryLoadFromJar(String siteKey, String cleanApi, String ext, String jar, boolean stripFirst) {
        ClassLoader loader = loadJar(jar);
        if (loader == null || loader == getClass().getClassLoader()) {
            return null;
        }
        // 加固载荷的播放地址是 http://127.0.0.1:<ProxyOrigin 端口>/proxy?...，
        // 手机端由宿主起本地服务；桌面端必须**先把服务起起来**：
        //   1) 服务先于 init 可用，init 里的 getOwnProxyUrl() 才有值可取；
        //   2) 即使端口注入失败（wexguard 的端口字段名与 yq 不同），服务本身仍然活着，
        //      载荷的端口探测（9978→10000）仍可能命中我们。
        GuardProxyServer.ensureStarted(loader);
        invokeSpiderJarInit(loader);
        // InitOrigin.init 可能重写端口字段：幂等复核一次（见 GuardProxyServer.reassertPort）
        GuardProxyServer.ensureStarted(loader);

        String stripped = cleanApi.endsWith("Guard") ? cleanApi.substring(0, cleanApi.length() - 5) : null;
        Class<?> spiderClass = null;

        if (stripFirst && stripped != null) {
            try {
                spiderClass = loader.loadClass("com.github.catvod.spider." + stripped);
                System.out.println("[DexSpiderLoader] Guard 后缀映射: " + cleanApi + " -> " + stripped);
            } catch (ClassNotFoundException ignored) {
            }
        }
        if (spiderClass == null) {
            try {
                spiderClass = loader.loadClass("com.github.catvod.spider." + cleanApi);
            } catch (ClassNotFoundException e) {
                // 加固(Guard)站点映射：csp_XxxGuard → 载荷类 com.github.catvod.spider.Xxx
                // （ftyguard/wexguard 解密载荷中的类名不带 Guard 后缀，如 WoGGGuard → WoGG）
                if (stripped != null) {
                    try {
                        spiderClass = loader.loadClass("com.github.catvod.spider." + stripped);
                        System.out.println("[DexSpiderLoader] Guard 后缀映射: " + cleanApi + " -> " + stripped);
                    } catch (ClassNotFoundException ignored) {
                    }
                }
                if (spiderClass == null) {
                    try {
                        spiderClass = loader.loadClass(cleanApi);
                    } catch (Throwable ignored) {
                    }
                }
            }
        }

        if (spiderClass == null) {
            return null;
        }

        try {
            Object instance = spiderClass.getDeclaredConstructor().newInstance();
            if (instance instanceof Spider) {
                return (Spider) instance;
            }
            return new GenericSpiderWrapper(instance, siteKey, ext);
        } catch (Throwable t) {
            ParseStage.fail(ParseStage.INSTANTIATE, spiderClass.getName() + ": " + t);
            System.err.println("[DexSpiderLoader] Failed to instantiate dynamic class " + spiderClass.getName() + ": " + t.getMessage());
            return null;
        }
    }

    /**
     * 类发现兜底：精确名失败后，在载荷里找 Spider 子类。
     *
     * <p>只做「结构性」判断（是否 Spider 子类、是否唯一），不做站名映射：
     * 多候选时返回 null 并打印候选清单 —— 挑错站点比明确失败更难排查。
     */
    private Spider tryDiscoverFromJar(String siteKey, String cleanApi, String ext, String jar) {
        ClassLoader loader = loadJar(jar);
        if (loader == null || loader == getClass().getClassLoader()) {
            return null;
        }
        List<String> names = spiderClasses(loader);
        if (names.isEmpty()) {
            return null;
        }
        String hinted = cleanApi.endsWith("Guard")
                ? cleanApi.substring(0, cleanApi.length() - 5) : cleanApi;
        String picked = pickDiscovered(names, hinted);
        if (picked == null) {
            String detail = "类未找到 api=" + cleanApi + " 候选=" + shortNames(names);
            ParseStage.fail(ParseStage.CLASS, detail);
            System.err.println("[DexSpiderLoader] " + detail);
            return null;
        }
        try {
            Class<?> cls = Class.forName(picked, false, loader);
            Object instance = cls.getDeclaredConstructor().newInstance();
            System.out.println("[DexSpiderLoader] 类发现兜底命中: " + cleanApi + " -> " + picked);
            if (instance instanceof Spider) {
                return (Spider) instance;
            }
            return new GenericSpiderWrapper(instance, siteKey, ext);
        } catch (Throwable t) {
            ParseStage.fail(ParseStage.INSTANTIATE, picked + ": " + t);
            System.err.println("[DexSpiderLoader] 类发现后实例化失败 " + picked + ": " + t);
            return null;
        }
    }

    /**
     * 从候选里选一个：全局唯一 → 名字精确 → 名字互相包含且唯一；否则 null。
     * 绝不返回「第一个」。
     */
    private String pickDiscovered(List<String> names, String hint) {
        if (names.size() == 1) return names.get(0);
        String h = hint == null ? "" : hint.toLowerCase(Locale.ROOT);
        if (h.isEmpty()) return null;
        List<String> exact = new ArrayList<>();
        List<String> fuzzy = new ArrayList<>();
        for (String name : names) {
            String simple = name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
            if (simple.equals(h)) {
                exact.add(name);
            } else if (simple.contains(h) || h.contains(simple)) {
                fuzzy.add(name);
            }
        }
        if (exact.size() == 1) return exact.get(0);
        if (exact.isEmpty() && fuzzy.size() == 1) return fuzzy.get(0);
        return null;
    }

    /**
     * 载荷内可实例化的 Spider 子类（按 loader 缓存，避免每次调用扫 zip）。
     *
     * <p>过滤规则只针对混淆产物结构：跳过 {@code com.github.catvod.spider.merge.*}
     * （壳框架的混淆类，数以千计）与首字母小写的内部类，避免把整个 dex 都 Class.forName 一遍。
     */
    private List<String> spiderClasses(ClassLoader loader) {
        List<String> cached = SPIDER_CLASSES.get(loader);
        if (cached != null) return cached;
        List<String> candidates = new ArrayList<>();
        try {
            if (loader instanceof URLClassLoader) {
                for (URL url : ((URLClassLoader) loader).getURLs()) {
                    File file;
                    try {
                        file = new File(url.toURI());
                    } catch (Throwable t) {
                        continue;
                    }
                    if (!file.isFile()) continue;
                    try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(file)) {
                        java.util.Enumeration<? extends java.util.zip.ZipEntry> it = zip.entries();
                        while (it.hasMoreElements()) {
                            String entry = it.nextElement().getName();
                            if (!entry.startsWith("com/github/catvod/spider/")) continue;
                            if (!entry.endsWith(".class") || entry.indexOf('$') >= 0) continue;
                            String cls = entry.substring(0, entry.length() - 6).replace('/', '.');
                            if (cls.startsWith("com.github.catvod.spider.merge.")) continue;
                            String simple = cls.substring(cls.lastIndexOf('.') + 1);
                            if (simple.isEmpty() || !Character.isUpperCase(simple.charAt(0))) continue;
                            candidates.add(cls);
                        }
                    }
                }
            }
        } catch (Throwable t) {
            System.err.println("[DexSpiderLoader] 扫描载荷类失败: " + t);
        }
        List<String> spiders = new ArrayList<>();
        for (String cls : candidates) {
            try {
                Class<?> c = Class.forName(cls, false, loader);
                if (!Spider.class.isAssignableFrom(c)) continue;
                if (c.isInterface() || java.lang.reflect.Modifier.isAbstract(c.getModifiers())) continue;
                spiders.add(cls);
            } catch (Throwable ignored) {
            }
        }
        System.out.println("[DexSpiderLoader] 载荷可实例化 Spider 子类: " + spiders.size() + " 个"
                + (spiders.isEmpty() ? "" : " " + shortNames(spiders)));
        List<String> result = java.util.Collections.unmodifiableList(spiders);
        SPIDER_CLASSES.put(loader, result);
        return result;
    }

    private String shortNames(List<String> names) {
        StringBuilder sb = new StringBuilder("[");
        int limit = Math.min(5, names.size());
        for (int i = 0; i < limit; i++) {
            if (i > 0) sb.append(", ");
            String name = names.get(i);
            sb.append(name.substring(name.lastIndexOf('.') + 1));
        }
        if (names.size() > limit) sb.append(", …");
        sb.append(']');
        return sb.toString();
    }

    /**
     * 许多第三方 spider jar（如 Yoursmile 系列）内置 com.github.catvod.spider.Init 宿主桥，
     * 其 Init.context() 返回的结果来自 Init.init(Context) 注入。宿主（手机端 APK）在启动时
     * 调用过一次；桌面端在加载 jar 后主动注入 Application 实例，行为对齐手机端。
     *
     * 加固(ftyguard/wexguard)解密载荷中没有 Init，但框架入口为 InitOrigin.init(Context)，
     * 必须同样注入，否则框架状态（Context/executor/本地代理）为 null，深层路径（播放/网盘）异常。
     */
    private void invokeSpiderJarInit(ClassLoader loader) {
        if (!invokeStaticInit(loader, "com.github.catvod.spider.Init")) {
            invokeStaticInit(loader, "com.github.catvod.spider.InitOrigin");
            injectGuardHostClass(loader);
            enableGuardHideUtils(loader);
        }
    }

    /**
     * 把 ftyguard 载荷切到 {@code HideUtils} 稳定接口，绕开随版本轮换的混淆方法名。
     *
     * <p>反编译当前载荷 {@code merge.g8} 可见每个加解密入口都是同一个二选一：
     * <pre>
     *   bl = uA.yq;
     *   ...
     *   if (bl) return HideUtils.decrypt(s);          // 桌面端希望走这里
     *   try { return (String) InitOrigin.i
     *           .getDeclaredMethod(&lt;7 个随机 Unicode 字符&gt;, String.class)
     *           .invoke(null, s); }                    // 方法名每代都变
     *   catch (Exception e) { ... return ""; }         // 失败即静默空串
     * </pre>
     * 也就是说：只要 (1) 宿主能提供 {@code com.github.catvod.spider.HideUtils}，
     * (2) 壳的开关字段为 true，载荷就完全不碰混淆名。
     *
     * <p>开关字段**不写死**：先扫描载荷，找出直接调用 HideUtils 的类，再收集它从
     * 其它类读取的 {@code public static boolean}（当前代就是 {@code merge.uA.yq}）。
     * 类名、字段名每代都可能变，但「引用 HideUtils 的类 + 它读的布尔开关」是壳的
     * 固定结构，可以跨代复用；扫描不到时才退回已知类名。
     *
     * <p>先确认 HideUtils 确实可解析，再置位——否则开关为 true 会让载荷抛
     * NoClassDefFoundError（Error 不被 catch(Exception) 捕获），比空串更糟。
     */
    private void enableGuardHideUtils(ClassLoader loader) {
        // 诊断/回滚开关：-Dxiugou.guard.hideutils=off 时保留旧的反射兜底路径。
        if ("off".equalsIgnoreCase(System.getProperty("xiugou.guard.hideutils"))) {
            return;
        }
        final String hideUtils = "com.github.catvod.spider.HideUtils";
        try {
            Class.forName(hideUtils, false, loader);
        } catch (Throwable missing) {
            System.err.println("[DexSpiderLoader] HideUtils unavailable, keep guard reflection fallback: " + missing);
            return;
        }
        try {
            List<String> flipped = new ArrayList<>();
            for (String spec : hideUtilsSwitches(loader)) {
                int hash = spec.lastIndexOf('#');
                String ownerName = spec.substring(0, hash).replace('/', '.');
                String fieldName = spec.substring(hash + 1);
                try {
                    Class<?> owner = Class.forName(ownerName, false, loader);
                    java.lang.reflect.Field flag = owner.getDeclaredField(fieldName);
                    int mod = flag.getModifiers();
                    if (!java.lang.reflect.Modifier.isStatic(mod)
                            || !java.lang.reflect.Modifier.isPublic(mod)
                            || flag.getType() != boolean.class) {
                        continue;
                    }
                    flag.setAccessible(true);
                    flag.setBoolean(null, true);
                    flipped.add(spec);
                } catch (Throwable ignored) {
                }
            }
            if (!flipped.isEmpty()) {
                System.out.println("[DexSpiderLoader] Guard branch switched to HideUtils (" + flipped + ")");
            }
        } catch (Throwable t) {
            System.err.println("[DexSpiderLoader] Guard HideUtils switch failed: " + t);
        }
    }

    /**
     * 扫描载荷，返回「走 HideUtils」的开关字段（格式 {@code owner#field}）。
     *
     * <p>判定规则只有两条，全部基于字节码结构，不依赖具体类名：
     * <ol>
     *   <li>该类调用了 {@code com.github.catvod.spider.HideUtils} 的方法；</li>
     *   <li>它对该类**以外**的 {@code boolean} 字段执行 GETSTATIC。</li>
     * </ol>
     * 当前代 {@code merge/g8.class} 命中的只有 {@code merge/uA#yq}；同一类里的
     * {@code g8.i} 因 owner==self 被排除（那是「已提示过」的状态位，置 true 会吞提示）。
     */
    private List<String> hideUtilsSwitches(ClassLoader loader) {
        final List<String> found = new ArrayList<>();
        final File jar = jarOf(loader);
        if (jar != null) {
            try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(jar)) {
                Enumeration<? extends java.util.zip.ZipEntry> entries = zip.entries();
                while (entries.hasMoreElements()) {
                    java.util.zip.ZipEntry entry = entries.nextElement();
                    if (!entry.getName().endsWith(".class")) continue;
                    byte[] bytes;
                    try (InputStream in = zip.getInputStream(entry)) {
                        bytes = readFully(in);
                    }
                    if (!referencesHideUtils(bytes)) continue;
                    collectGuardSwitches(bytes, entry.getName(), found);
                }
            } catch (Throwable t) {
                System.err.println("[DexSpiderLoader] Guard switch scan failed: " + t);
            }
        }
        if (found.isEmpty()) {
            // 兜底：本机实测的 ftyguard 42869e 代际（merge.uA.yq）。
            try {
                Class.forName("com.github.catvod.spider.merge.uA", false, loader).getDeclaredField("yq");
                found.add("com/github/catvod/spider/merge/uA#yq");
            } catch (Throwable ignored) {
            }
        }
        return found;
    }

    private File jarOf(ClassLoader loader) {
        if (!(loader instanceof URLClassLoader)) return null;
        for (URL url : ((URLClassLoader) loader).getURLs()) {
            if (!"file".equals(url.getProtocol())) continue;
            try {
                File file = new File(url.toURI());
                if (file.isFile() && file.getName().endsWith(".jar")) return file;
            } catch (Throwable ignored) {
            }
        }
        return null;
    }

    private byte[] readFully(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(1024, in.available()));
        byte[] buffer = new byte[8192];
        int read;
        while ((read = in.read(buffer)) != -1) {
            out.write(buffer, 0, read);
        }
        return out.toByteArray();
    }

    private boolean referencesHideUtils(byte[] bytes) {
        final boolean[] hit = {false};
        new org.objectweb.asm.ClassReader(bytes).accept(
                new org.objectweb.asm.ClassVisitor(org.objectweb.asm.Opcodes.ASM9) {
                    @Override
                    public org.objectweb.asm.MethodVisitor visitMethod(int access, String name, String desc,
                            String sig, String[] ex) {
                        return new org.objectweb.asm.MethodVisitor(org.objectweb.asm.Opcodes.ASM9) {
                            @Override
                            public void visitMethodInsn(int op, String owner, String name, String desc, boolean itf) {
                                if ("com/github/catvod/spider/HideUtils".equals(owner)) hit[0] = true;
                            }
                        };
                    }
                }, org.objectweb.asm.ClassReader.SKIP_DEBUG | org.objectweb.asm.ClassReader.SKIP_FRAMES);
        return hit[0];
    }

    private void collectGuardSwitches(byte[] bytes, String entryName, List<String> out) {
        final String self = entryName.substring(0, entryName.length() - ".class".length());
        new org.objectweb.asm.ClassReader(bytes).accept(
                new org.objectweb.asm.ClassVisitor(org.objectweb.asm.Opcodes.ASM9) {
                    @Override
                    public org.objectweb.asm.MethodVisitor visitMethod(int access, String name, String desc,
                            String sig, String[] ex) {
                        return new org.objectweb.asm.MethodVisitor(org.objectweb.asm.Opcodes.ASM9) {
                            @Override
                            public void visitFieldInsn(int op, String owner, String name, String desc) {
                                if (op != org.objectweb.asm.Opcodes.GETSTATIC || !"Z".equals(desc)) return;
                                if (self.equals(owner)) return;
                                String spec = owner + "#" + name;
                                if (!out.contains(spec)) out.add(spec);
                            }
                        };
                    }
                }, org.objectweb.asm.ClassReader.SKIP_DEBUG | org.objectweb.asm.ClassReader.SKIP_FRAMES);
    }

    /**
     * 加固载荷的多个站点（Seedhub/T4/AppTT/AppSx/App99 等）通过
     * InitOrigin.i（宿主 App 的 Class）反射调用宿主静态方法
     * （encrypt/decrypt/native_ting_md5/calcResult，见 merge.ME）。
     * 手机端 i 指向壳 DexNative（native 实现）；桌面端注入 Java 近似实现 GuardHost。
     * 兜底：若 GuardHost 不存在则注入 com.fongmi.android.tv.App stub。
     */
    private void injectGuardHostClass(ClassLoader loader) {
        try {
            Class<?> initOrigin = loader.loadClass("com.github.catvod.spider.InitOrigin");
            java.lang.reflect.Field iField;
            try {
                iField = initOrigin.getDeclaredField("i");
            } catch (NoSuchFieldException notFtyShell) {
                // wexguard 等其它壳的 InitOrigin 没有"宿主 Class"字段（它们的配置由
                // InitOrigin.init(Context) 自己填充十几项 JSONObject/字符串），
                // 不需要也无法注入 GuardHost，安静跳过即可。
                return;
            }
            iField.setAccessible(true);
            if (iField.get(null) != null) {
                return;
            }
            Class<?> hostClass;
            try {
                hostClass = Class.forName("com.fongmi.companion.GuardHost");
            } catch (ClassNotFoundException e) {
                hostClass = Class.forName("com.fongmi.android.tv.App");
            }
            java.lang.reflect.Method setClass = initOrigin.getMethod("setClass", Class.class);
            setClass.invoke(null, hostClass);
            System.out.println("[DexSpiderLoader] Injected host class into InitOrigin.i: " + hostClass.getName());
        } catch (Throwable t) {
            System.err.println("[DexSpiderLoader] Host class injection failed: " + t);
        }
    }

    private boolean invokeStaticInit(ClassLoader loader, String className) {
        try {
            Class<?> initCls = loader.loadClass(className);
            try {
                java.lang.reflect.Method init = initCls.getMethod("init", android.content.Context.class);
                init.invoke(null, android.app.Application.get());
                System.out.println("[DexSpiderLoader] Invoked " + className + ".init(Application) for spider jar");
                return true;
            } catch (NoSuchMethodException ignored) {
            }
        } catch (ClassNotFoundException ignored) {
        } catch (Throwable t) {
            // InvocationTargetException 的 message 永远是 null，必须展开 cause 才能定位
            // 载荷 <clinit>/init 里真正抛了什么（例如缺某个 android.* shim）。
            Throwable cause = (t instanceof java.lang.reflect.InvocationTargetException && t.getCause() != null)
                    ? t.getCause() : t;
            ParseStage.fail(ParseStage.INIT, className + ": " + cause);
            System.err.println("[DexSpiderLoader] " + className + ".init injection failed: " + cause);
            if (cause != t) {
                cause.printStackTrace();
            }
        }
        return false;
    }

    private Class<?> findBuiltinSpiderClass(String cleanApi) {
        String[] candidateNames = new String[] {
            "com.github.catvod.spider." + cleanApi,
            "com.github.catvod.spider." + capitalize(cleanApi),
            "com.github.catvod.spider." + cleanApi.toUpperCase(Locale.ROOT)
        };

        for (String name : candidateNames) {
            try {
                return Class.forName(name);
            } catch (ClassNotFoundException ignored) {}
        }

        // Try alias lookup
        String alias = ALIAS_MAP.get(cleanApi.toLowerCase(Locale.ROOT));
        if (alias != null) {
            try {
                return Class.forName("com.github.catvod.spider." + alias);
            } catch (ClassNotFoundException ignored) {}
        }

        return null;
    }

    private String normalizeApiName(String api) {
        if (api == null || api.trim().isEmpty()) return "";
        String clean = api.trim();
        if (clean.startsWith("csp_")) {
            clean = clean.substring(4);
        } else if (clean.startsWith("csp")) {
            clean = clean.substring(3);
        }
        return clean;
    }

    private String capitalize(String str) {
        if (str == null || str.isEmpty()) return str;
        return Character.toUpperCase(str.charAt(0)) + str.substring(1);
    }

    public ClassLoader loadJar(String jarSpec) {
        if (jarSpec == null || jarSpec.trim().isEmpty()) {
            return getClass().getClassLoader();
        }

        String jarKey = loaderKey(jarSpec);
        ClassLoader cached = loaders.get(jarKey);
        if (cached != null) return cached;

        URLClassLoader created;
        try {
            File localJar = resolveJarFile(jarSpec);
            if (localJar == null || !localJar.exists()) {
                // **失败结果不缓存**：下载/解密可能是暂时性的（网络抖动、首次解密未完成）。
                // 缓存成父加载器会让该 jar 在进程存活期内永远加载不到，表现为「站点一直空白」。
                System.err.println("[DexSpiderLoader] Jar file could not be resolved: " + jarSpec);
                return getClass().getClassLoader();
            }

            File usableJar = ensureJvmJar(localJar);
            // 静态体检：载荷里若含 ARM-only 原生库（如壳的 libLoadNiMa.so），
            // 依赖它的站点在本机必然是 0 数据。这里只做一次、不阻塞加载。
            try {
                com.fongmi.companion.selfcheck.PayloadInspector.reportOnce(localJar);
            } catch (Throwable ignored) {
            }
            created = new URLClassLoader(new URL[]{usableJar.toURI().toURL()}, getClass().getClassLoader());
        } catch (Throwable t) {
            System.err.println("[DexSpiderLoader] Failed to load jar: " + jarSpec + ", err: " + t.getMessage());
            return getClass().getClassLoader();
        }
        ClassLoader existing = loaders.putIfAbsent(jarKey, created);
        return existing != null ? existing : created;
    }

    /**
     * 手机端 spider jar 常为 Android 容器：zip 内只有 classes.dex（无 JVM .class），
     * 由 Android 的 PathClassLoader 直接加载。标准 JVM 无法加载 dex，需要先转换为
     * JVM class jar（dex2jar）。转换结果按源文件 md5 缓存，避免重复转换。
     */
    private File ensureJvmJar(File jarFile) {
        try {
            boolean hasDex = false;
            boolean hasClass = false;
            try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(jarFile)) {
                java.util.Enumeration<? extends java.util.zip.ZipEntry> entries = zip.entries();
                while (entries.hasMoreElements()) {
                    String name = entries.nextElement().getName();
                    if (name.equals("classes.dex") || (name.startsWith("classes") && name.endsWith(".dex"))) {
                        hasDex = true;
                    } else if (name.endsWith(".class")) {
                        hasClass = true;
                    }
                }
            }
            if (!hasDex || hasClass) {
                return jarFile; // 标准 JVM jar 或非 dex 容器，直接使用
            }

            String base = jarFile.getName();
            if (base.endsWith(".jar")) base = base.substring(0, base.length() - 4);
            // -jvm7：转换器改为 PreciseDex2jar（保留 new-instance 的真实分配类型，不再塌缩成父类）。
            // 旧缓存（-jvm 至 -jvm6）是塌缩产物或基于启发式补点位的产物，直接换名作废。
            File converted = new File(cacheDir, base + "-jvm7.jar");
            if (converted.exists() && converted.length() > 0
                    && converted.lastModified() >= jarFile.lastModified()) {
                return converted;
            }

            System.out.println("[DexSpiderLoader] Converting dex jar to JVM jar: " + jarFile.getName());
            long t0 = System.currentTimeMillis();
            File tmp = new File(cacheDir, base + "-jvm7.tmp.jar");
            PreciseDex2jar.Result result = PreciseDex2jar.convert(jarFile, tmp.toPath());
            if (tmp.exists() && tmp.length() > 0) {
                // 修补 dex2jar 十六进制字符串表还原产生的 arraycopy 反向；
                // 修补失败就退回未修补产物（不影响既有站点）。
                if (!Dex2jarRepair.repair(tmp, converted)) {
                    java.nio.file.Files.move(tmp.toPath(), converted.toPath(),
                            java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                }
                tmp.delete();
                System.out.println("[DexSpiderLoader] Dex2jar done in " + (System.currentTimeMillis() - t0)
                        + "ms -> " + converted.getName() + " (" + converted.length() + " bytes, "
                        + result.classes + " classes, 保留真实分配类型 " + result.keptMismatchedNew + " 处)");
                converted.setLastModified(System.currentTimeMillis());
                return converted;
            }
            ParseStage.fail(ParseStage.DEX2JAR, "dex2jar 输出为空: " + jarFile.getName());
            System.err.println("[DexSpiderLoader] Dex2jar produced empty output for: " + jarFile);
            return jarFile;
        } catch (Throwable t) {
            ParseStage.fail(ParseStage.DEX2JAR, jarFile.getName() + ": " + t);
            System.err.println("[DexSpiderLoader] Dex2jar failed: " + t.getMessage()
                    + " (falling back to raw jar)");
            return jarFile;
        }
    }

    private File resolveJarFile(String jarSpec) {
        try {
            String[] parts = jarSpec.split(";md5;");
            String rawUrl = parts[0].trim();
            String expectedMd5 = parts.length > 1 ? parts[1].trim() : "";

            if (rawUrl.startsWith("file://") || rawUrl.startsWith("/") || (rawUrl.length() > 2 && rawUrl.charAt(1) == ':')) {
                String cleanPath = rawUrl.startsWith("file://") ? rawUrl.substring(7) : rawUrl;
                File file = new File(cleanPath);
                if (file.exists()) return file;
            }

            if (rawUrl.startsWith("http://") || rawUrl.startsWith("https://")) {
                // 加固(ftyguard/wexguard)载荷缓存：优先按「壳内容 md5」命中，
                // 再按「URL md5」命中。同一份壳会被多个域名分发（例如
                // qist.wyfc.qzz.io/jar/fan.txt 与 xiuxiu-pro-new…/posters/xxx.jpg
                // 是同一个 1,281,099 B / md5 aa8d… 的加密壳），按 URL 缓存会在
                // 换域名时全部失效，按内容 md5 则跨域名复用同一份解密载荷。
                if (!expectedMd5.isEmpty()) {
                    File payloadJar = new File(cacheDir,
                            "payload-" + expectedMd5.toLowerCase(Locale.ROOT) + ".jar");
                    if (payloadJar.exists() && payloadJar.length() > 0) {
                        System.out.println("[DexSpiderLoader] 命中按壳 md5 缓存的载荷: " + payloadJar.getName());
                        // 载荷命中时壳 jar 不会走到下面分支，这里按确定性文件名补记一次，
                        // 让「表里没有的密文」仍能问壳。
                        File shell = new File(cacheDir, md5(rawUrl) + ".jar");
                        if (shell.isFile()) GuardCryptoService.rememberShellJar(shell);
                        return payloadJar;
                    }
                }

                // 加固(ftyguard/wexguard) jar：本地已解密的守卫载荷优先于原壳 jar
                // （guard-<url md5>.jar 由解密流程预置到 jars 缓存目录）
                File guardJar = new File(cacheDir, "guard-" + md5(rawUrl) + ".jar");
                if (guardJar.exists() && guardJar.length() > 0) {
                    System.out.println("[DexSpiderLoader] 命中本地守卫载荷: " + guardJar.getName());
                    return guardJar;
                }

                String filename = md5(rawUrl) + ".jar";
                File cachedFile = new File(cacheDir, filename);
                if (cachedFile.exists() && cachedFile.length() > 0) {
                    if (expectedMd5.isEmpty() || md5File(cachedFile).equalsIgnoreCase(expectedMd5)) {
                        // 壳已缓存但载荷还没解出来（老版本遗留 / 上次解密失败）→ 就地补解
                        GuardCryptoService.rememberShellJar(cachedFile);
                        File provisioned = GuardPayloadProvisioner.ensure(cacheDir, cachedFile, expectedMd5, rawUrl);
                        if (provisioned != null) return provisioned;
                        return cachedFile;
                    }
                    // 缓存内容与配置声明的 md5 不符：删掉重下，避免「换配置后一直用旧壳」
                    String stale = md5File(cachedFile);
                    ParseStage.fail(ParseStage.MD5, "缓存 md5 不符（期望 " + expectedMd5 + "，实际 " + stale
                            + "），已删除: " + cachedFile.getName());
                    System.err.println("[DexSpiderLoader] 缓存 md5 不符（期望 " + expectedMd5
                            + "，实际 " + stale + "），删除后重新下载: " + cachedFile.getName());
                    cachedFile.delete();
                }

                System.out.println("[DexSpiderLoader] Downloading jar from: " + rawUrl);
                URL url = URI.create(rawUrl).toURL();
                java.net.URLConnection conn = url.openConnection();
                conn.setConnectTimeout(15000);
                conn.setReadTimeout(60000);
                try (InputStream in = conn.getInputStream()) {
                    Files.copy(in, cachedFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
                // 配置里带 ;md5; 就必须核对：否则「配置写错」会拿着一份错误内容一路跑到
                // dex2jar/类加载才炸，定位成本极高（见方案 P1-1 的 md5 阶段）。
                verifyDownloadedMd5(cachedFile, expectedMd5, rawUrl);
                if (!cachedFile.exists() || cachedFile.length() == 0) {
                    return null;
                }
                // 下载完才发现是加固壳：就地自动解密出载荷（首次约 10 s，之后按壳 md5 复用）
                GuardCryptoService.rememberShellJar(cachedFile);
                File provisioned = GuardPayloadProvisioner.ensure(cacheDir, cachedFile, expectedMd5, rawUrl);
                if (provisioned != null) return provisioned;
                return cachedFile;
            }
        } catch (Throwable t) {
            // 下载/网络最常在这一层炸（含 404 / DNS / 超时）
            ParseStage.fail(ParseStage.DOWNLOAD, jarSpec + " -> " + t);
            System.err.println("[DexSpiderLoader] Resolve error: " + t.getMessage());
        }
        if (ParseStage.current() == null) {
            ParseStage.fail(ParseStage.RESOLVE, "jar 无法解析: " + jarSpec);
        }
        return null;
    }

    /**
     * 下载后校验 md5。
     *
     * <p>软/硬两种处理：
     * <ul>
     *   <li>内容仍是可解压的 zip → 只告警并记 stage=md5，继续尝试
     *       （很多配置里的 md5 是过期抄写，硬失败会误伤可用站点）；</li>
     *   <li>内容不是 zip（下到了错误页/文本）→ 删除并失败，避免下游把它当 jar。</li>
     * </ul>
     */
    private void verifyDownloadedMd5(File file, String expectedMd5, String rawUrl) {
        if (expectedMd5 == null || expectedMd5.trim().isEmpty()) return;
        String actual = md5File(file);
        if (actual.equalsIgnoreCase(expectedMd5.trim())) return;
        String msg = "下载内容 md5 不符（期望 " + expectedMd5.trim() + "，实际 " + actual + "）: " + rawUrl;
        ParseStage.fail(ParseStage.MD5, msg);
        if (looksLikeZip(file)) {
            System.err.println("[DexSpiderLoader] " + msg + "（内容可解压，继续尝试）");
        } else {
            System.err.println("[DexSpiderLoader] " + msg + "（内容不是 zip，放弃）");
            file.delete();
        }
    }

    /** 只看 zip 魔数（PK\\003\\004 / PK\\005\\006 / PK\\007\\008），不展开。 */
    private boolean looksLikeZip(File file) {
        try (InputStream in = new FileInputStream(file)) {
            byte[] head = new byte[4];
            if (in.read(head) < 4) return false;
            return head[0] == 'P' && head[1] == 'K' && (head[2] == 3 || head[2] == 5 || head[2] == 7);
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * ClassLoader 缓存键。
     *
     * 同一份加固壳会被多个域名分发（`…/jar/fan.txt` 与 `…/posters/xxx.jpg` 是同一份
     * md5 aa8d… 的容器）；若按整串 URL 建键，每个域名都会新建一个 ClassLoader，
     * 也就是每个域名一份 `ProxyOrigin.yq` 静态状态 + 一个本地代理端口，播放地址
     * 里的端口号会随调用顺序漂移。带 `;md5;` 时按内容 md5 建键即可全局唯一。
     */
    private String loaderKey(String jarSpec) {
        String[] parts = jarSpec.split(";md5;");
        if (parts.length > 1) {
            String contentMd5 = parts[1].trim().toLowerCase(Locale.ROOT);
            if (!contentMd5.isEmpty()) return "md5:" + contentMd5;
        }
        return md5(jarSpec);
    }

    private static String md5(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : digest) {
                sb.append(String.format("%02x", b & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(input.hashCode());
        }
    }

    private static String md5File(File file) {
        try (InputStream is = new FileInputStream(file)) {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) != -1) {
                md.update(buf, 0, n);
            }
            byte[] digest = md.digest();
            StringBuilder sb = new StringBuilder();
            for (byte b : digest) {
                sb.append(String.format("%02x", b & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    private static class GenericSpiderWrapper extends Spider {
        private final Object target;

        public GenericSpiderWrapper(Object target, String siteKey, String ext) {
            this.target = target;
            this.siteKey = siteKey;
            try {
                Method initMethod = target.getClass().getMethod("init", Context.class, String.class);
                initMethod.invoke(target, Context.get(), ext != null ? ext : "");
            } catch (Throwable t) {
                try {
                    Method initMethod = target.getClass().getMethod("init", Context.class);
                    initMethod.invoke(target, Context.get());
                } catch (Throwable ignored) {}
            }
        }

        @Override
        public String homeContent(boolean filter) throws Exception {
            Method m = target.getClass().getMethod("homeContent", boolean.class);
            return String.valueOf(m.invoke(target, filter));
        }

        @Override
        public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
            Method m = target.getClass().getMethod("categoryContent", String.class, String.class, boolean.class, HashMap.class);
            return String.valueOf(m.invoke(target, tid, pg, filter, extend));
        }

        @Override
        public String detailContent(List<String> ids) throws Exception {
            Method m = target.getClass().getMethod("detailContent", List.class);
            return String.valueOf(m.invoke(target, ids));
        }

        @Override
        public String searchContent(String key, boolean quick) throws Exception {
            try {
                Method m = target.getClass().getMethod("searchContent", String.class, boolean.class);
                return String.valueOf(m.invoke(target, key, quick));
            } catch (NoSuchMethodException e) {
                Method m = target.getClass().getMethod("searchContent", String.class, boolean.class, String.class);
                return String.valueOf(m.invoke(target, key, quick, "1"));
            }
        }

        @Override
        public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
            Method m = target.getClass().getMethod("playerContent", String.class, String.class, List.class);
            return String.valueOf(m.invoke(target, flag, id, vipFlags));
        }

        @Override
        public void destroy() {
            try {
                Method m = target.getClass().getMethod("destroy");
                m.invoke(target);
            } catch (Throwable ignored) {}
        }
    }
}
