package com.fongmi.companion;

import android.content.Context;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;
import com.github.catvod.spider.UnsupportedGuardSpider;
import com.fongmi.companion.hardshell.HardshellPipeline;
import com.fongmi.companion.py.PySpider;
import com.fongmi.companion.d2j.PreciseDex2jar;
import com.fongmi.companion.guard.GuardCryptoService;
import com.fongmi.companion.source.SourceRules;
import com.fongmi.companion.source.SpiderFactoryRegistry;
import com.fongmi.companion.source.SpiderRequest;

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
    /** 正在准备中的 jar（按 jarKey 单飞）：同一个 jar 只让一个线程下载/解密/转换。 */
    private final ConcurrentHashMap<String, java.util.concurrent.CompletableFuture<JarOutcome>> JAR_LOADING =
            new ConcurrentHashMap<>();
    private record JarOutcome(ClassLoader loader, ParseStage.Failure failure) {}
    private static final class SpiderAttempt {
        ParseStage.Failure failure;
    }
    private final ThreadLocal<SpiderAttempt> spiderAttempt = new ThreadLocal<>();
    /**
     * 同时进行「准备」的 jar 上限。
     *
     * <p>全串行会让多个源的首次加载互相排队（3 个 jar 就是 3×10 秒）；
     * 完全不限又会叠加 dex2jar 的 CPU/内存峰值。取中间：最多 2 个并行。
     */
    private static final java.util.concurrent.Semaphore JAR_PREP_SLOTS =
            new java.util.concurrent.Semaphore(2);
    /** dex→JVM 转换最近一次失败的时间（按 jarKey）：冷却期内不重试转换，直接退回宿主。 */
    private final ConcurrentHashMap<String, Long> jvmJarFailures = new ConcurrentHashMap<>();
    /** 按目标文件加锁：不同 jarKey 可能落到同一个缓存文件（同 URL 带 / 不带 md5）。 */
    private static final ConcurrentHashMap<String, Object> FILE_LOCKS = new ConcurrentHashMap<>();
    /** dex→JVM 转换失败后的重试冷却。 */
    private static final long JVM_JAR_RETRY_MS = 30_000L;
    /** 下载 / 转换的独占工作目录前缀（cacheDir 下），完成后原子发布到正式文件名。 */
    private static final String WORK_PREFIX = ".xgtmp-";
    /** 工作目录超过这个时长没有任何写入，视为进程异常退出的残留。 */
    private static final long STALE_WORK_MS = 10 * 60_000L;
    private final ConcurrentHashMap<String, Spider> spiders = new ConcurrentHashMap<>();
    /**
     * 按 spider 缓存键的创建锁：同一站点并发加载（如 /spider/load 与 /spider/call 同时到达）只创建一个实例。
     * 不同站点互不阻塞（加固载荷首次解密约 10 s，不能让其它站点排队）。
     */
    private final ConcurrentHashMap<String, Object> spiderLocks = new ConcurrentHashMap<>();
    /** 载荷内 Spider 子类扫描缓存（按 loader）——类发现兜底用，避免每次调用扫 zip。 */
    private static final Map<ClassLoader, List<String>> SPIDER_CLASSES =
            java.util.Collections.synchronizedMap(new java.util.WeakHashMap<ClassLoader, List<String>>());
    private final File cacheDir;

    /**
     * 已完成 jar 级初始化（代理服务 + Init/InitOrigin/载荷入口）的 loader。
     * 弱引用：loader 被丢弃后自动移除，不延长其生命周期。
     */
    private static final Set<ClassLoader> PREPARED =
            java.util.Collections.synchronizedSet(java.util.Collections.newSetFromMap(new java.util.WeakHashMap<>()));
    /** loader → 加固载荷的初始化入口类（见 ShellProfile#payloadInit）。 */
    private static final Map<ClassLoader, String> PAYLOAD_INIT =
            java.util.Collections.synchronizedMap(new java.util.WeakHashMap<>());

    /** 例外规则（别名 / 默认 ext / 拦截），全部来自数据文件，见 {@link SourceRules}。 */
    private final SourceRules rules;
    /** spider 工厂链：新增源类型在这里注册，不改 {@link #getSpider}。 */
    private final SpiderFactoryRegistry factories = new SpiderFactoryRegistry();

    public DexSpiderLoader() {
        String userHome = System.getProperty("user.home", ".");
        this.cacheDir = new File(new File(userHome, ".xiugou_tv_companion"), "jars");
        if (!cacheDir.exists()) {
            cacheDir.mkdirs();
        }
        purgeObsoleteArtifacts(cacheDir);
        this.rules = SourceRules.load(cacheDir.getParentFile());
        System.out.println("[DexSpiderLoader] " + rules);
        registerBuiltinFactories();
    }

    /** 作废的旧转换产物：-jvm.jar ~ -jvm6.jar（转换器已升级到 -jvm7）。 */
    private static final java.util.regex.Pattern OBSOLETE_JVM =
            java.util.regex.Pattern.compile(".*-jvm[0-6]?\\.jar");
    /** 临时产物只清理足够旧的，避免误删另一实例正在写的文件。 */
    private static final long STALE_TMP_MS = 10 * 60_000L;

    /**
     * 启动时清理 jars 缓存里的作废产物，只删三类：旧版本转换产物、残留的 *.tmp.jar、
     * 已有带修补戳版本时的无戳 -jvm7.jar。此时本进程尚未加载任何 jar；
     * 被其它进程占用的文件在 Windows 上删除会失败，直接跳过。其余缓存（原始 jar 等）不动。
     */
    static int purgeObsoleteArtifacts(File dir) {
        File[] files = dir.listFiles();
        if (files == null) return 0;
        java.util.Set<String> names = new java.util.HashSet<>();
        for (File f : files) names.add(f.getName());
        long now = System.currentTimeMillis();
        int removed = 0;
        long bytes = 0;
        for (File f : files) {
            if (!f.isFile()) continue;
            String name = f.getName();
            boolean obsolete;
            if (name.endsWith(".tmp.jar")) {
                obsolete = now - f.lastModified() > STALE_TMP_MS;
            } else if (OBSOLETE_JVM.matcher(name).matches()) {
                obsolete = true;
            } else if (name.endsWith("-jvm7.jar")) {
                String prefix = name.substring(0, name.length() - ".jar".length()) + "-";
                obsolete = false;
                for (String other : names) {
                    if (other.startsWith(prefix) && other.endsWith(".jar") && !other.endsWith(".tmp.jar")) {
                        obsolete = true;
                        break;
                    }
                }
            } else {
                obsolete = false;
            }
            if (!obsolete) continue;
            long len = f.length();
            if (f.delete()) {
                removed++;
                bytes += len;
            }
        }
        if (removed > 0) {
            System.out.println("[DexSpiderLoader] 清理作废缓存 " + removed + " 个，释放 " + (bytes >> 10) + " KB");
        }
        return removed;
    }

    /** 工厂链（可追加新的源类型）。 */
    public SpiderFactoryRegistry factories() {
        return factories;
    }

    /**
     * 内置工厂，顺序即历史上的加载层级（数字留间隔，新类型可插在任意两层之间）。
     *
     * <ol>
     *   <li>100 py：api 指向 .py，交给子进程 CPython，与 jar/JS 无关；判定只看后缀。</li>
     *   <li>200 js：ext 里带 {@code "js"} 的 extra.js 适配格式。</li>
     *   <li>300 guard-jar：{@code csp_XxxGuard} 优先从外部载荷加载。必须早于内置别名，
     *       否则会被 appttguard → AppYsV2 这类兼容映射劫持，拿不到载荷里的真实爬虫。</li>
     *   <li>400 jar-discover-early：载荷类名不带 Guard 后缀（Bili / Nmyswv…）时按结构发现。
     *       同样必须早于内置别名：内置 Bili 只有硬编码分类，DouDou 直接不支持，
     *       落到别名就会「首页有分类、点进去列表恒空」。</li>
     *   <li>500 builtin：companion 自带的实现（含 {@link SourceRules} 别名）。</li>
     *   <li>600 jar：普通外部 jar 按类名加载。</li>
     *   <li>700 jar-discover：精确名全失败后的类发现兜底，多候选一律放弃。</li>
     * </ol>
     * 下载/校验/解密这类与类名无关的硬失败（{@link #hardStop}）之后，jar 相关工厂不再重试同一 jar。
     */
    private void registerBuiltinFactories() {
        factories.register("py", 100,
                r -> PySpider.isPythonApi(r.api()) ? new PySpider(r.api(), r.ext(), cacheDir) : null);
        factories.register("js", 200,
                r -> r.ext() != null && r.ext().contains("\"js\"") ? new JavaScriptSpider(r.api(), r.ext()) : null);
        // py/js may inherit a global jar without using it; prepare only after those factories.
        factories.register("jar-prepare", 250, r -> {
            if (r.hasJar()) loadJar(r.jar());
            return null;
        });
        factories.register("guard-jar", 300,
                r -> r.cleanApi().endsWith("Guard") && r.hasJar() && !hardStop()
                        ? attemptJar(() -> tryLoadFromJar(r.siteKey(), r.cleanApi(), r.ext(), r.jar(), true)) : null);
        factories.register("jar-discover-early", 400,
                r -> r.hasJar() && !hardStop()
                        ? attemptJar(() -> tryDiscoverFromJar(r.siteKey(), r.cleanApi(), r.ext(), r.jar())) : null);
        factories.register("builtin", 500, r -> !r.hasJar() || !hardStop() ? createBuiltin(r) : null);
        factories.register("jar", 600,
                r -> r.hasJar() && !hardStop()
                        ? attemptJar(() -> tryLoadFromJar(r.siteKey(), r.cleanApi(), r.ext(), r.jar(), false)) : null);
        factories.register("jar-discover", 700,
                r -> r.hasJar() && !hardStop()
                        ? attemptJar(() -> tryDiscoverFromJar(r.siteKey(), r.cleanApi(), r.ext(), r.jar())) : null);
    }

    public File getCacheDir() {
        return cacheDir;
    }

    /**
     * 释放全部 spider 与类加载器（换配置 / 停机时调用）。
     *
     * <p>先从缓存摘下再销毁：并发的新请求只会看到空缓存并重建，不会拿到正在销毁的实例。
     * {@code URLClassLoader} 必须 close：否则 jar 文件句柄一直开着（Windows 下锁文件，
     * 换配置后删不掉、覆盖不了旧 jar），元空间也要等 GC 碰巧回收。
     *
     * @return 释放的 spider 个数
     */
    public int clear() {
        List<Spider> oldSpiders = new ArrayList<>(spiders.values());
        List<ClassLoader> oldLoaders = new ArrayList<>(loaders.values());
        spiders.clear();
        loaders.clear();
        spiderLocks.clear();
        for (Spider spider : oldSpiders) {
            try {
                spider.destroy();
            } catch (Throwable ignored) {}
        }
        for (ClassLoader cl : oldLoaders) {
            // 先停掉该载荷投递的心跳 / 延迟任务：自我重投的任务若不取消会永远循环，
            // 关闭类加载器也释放不了它（任务对象本身就引用着载荷类）
            int cancelled = android.os.Handler.cancelAll(cl);
            if (cancelled > 0) {
                System.out.println("[DexSpiderLoader] 已取消旧载荷的异步任务 " + cancelled + " 个");
            }
            if (cl instanceof URLClassLoader) {
                try {
                    ((URLClassLoader) cl).close();
                } catch (Throwable ignored) {}
            }
        }
        // 本地代理持有端口与线程；配置切换后旧 loader 不再使用，必须一并释放
        GuardProxyServer.releaseAll();
        ParseStage.reset();
        SPIDER_CLASSES.clear();
        return oldSpiders.size();
    }

    public Spider getSpider(String siteKey, String api, String ext, String jar) {
        String cleanApi = normalizeApiName(api);
        // 崩溃站必须在 Level 0（载荷加载）之前短路，否则进程直接消失。
        if (rules.isBlocked(cleanApi)) {
            System.err.println("[DexSpiderLoader] 已禁用会在本机 JDK 上崩溃的载荷: api=" + api
                    + " site=" + siteKey + "（加载它会触发 SIGSEGV，拖死整个 companion）");
            return new UnsupportedGuardSpider();
        }
        if (ext == null || ext.trim().isEmpty()) {
            String fallback = rules.defaultExt(cleanApi);
            if (fallback != null) {
                ext = fallback;
            }
        }
        String jarKey = md5(jar != null ? jar : "default");
        String spKey = jarKey + "_" + siteKey + "_" + cleanApi;

        Spider cached = spiders.get(spKey);
        if (cached != null) return cached;

        synchronized (spiderLocks.computeIfAbsent(spKey, k -> new Object())) {
            // 锁内复查：并发的另一请求可能已经建好
            cached = spiders.get(spKey);
            if (cached != null) return cached;
            Spider spider = null;
            SpiderAttempt previousAttempt = spiderAttempt.get();
            spiderAttempt.set(new SpiderAttempt());
            try {
                spider = factories.create(new SpiderRequest(siteKey, api, cleanApi, ext, jar));
                if (spider != null) {
                    spider.siteKey = siteKey;
                    spider.init(Context.get(), ext != null ? ext : "");
                    ParseStage.clearFailure();
                    System.out.println("[DexSpiderLoader] Successfully initialized spider: " + cleanApi + " for site: " + siteKey);
                    spiders.put(spKey, spider);
                    return spider;
                }
            } catch (Throwable t) {
                ParseStage.fail(spider != null ? ParseStage.INIT : ParseStage.INSTANTIATE, cleanApi + ": " + t);
                ParseStage.Failure stage = ParseStage.current();
                System.err.println("[DexSpiderLoader] Error instantiating spider " + cleanApi + ": " + t.getMessage()
                        + (stage != null ? "（阶段=" + stage.stage + "）" : ""));
                t.printStackTrace();
                // 失败不缓存，下次会重建：已创建的实例必须当场销毁，否则 python 子进程 / JS 上下文每次失败都泄漏一份
                if (spider != null) {
                    try {
                        spider.destroy();
                    } catch (Throwable ignored) {
                    }
                }
            } finally {
                SpiderAttempt attempt = spiderAttempt.get();
                if (attempt != null && attempt.failure != null) {
                    ParseStage.fail(attempt.failure.stage, attempt.failure.detail);
                }
                if (previousAttempt == null) spiderAttempt.remove();
                else spiderAttempt.set(previousAttempt);
            }
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

    /**
     * 把原始 jar 里的非 class 条目（assets 等资源）补进转换产物。
     *
     * <p>dex2jar 只产出 {@code .class}，载荷自己带的 {@code assets/*.so}、{@code *.html}
     * 会被整包丢掉，运行期就变成「Resource not found: assets/xxx.so」。
     * 这类资源是载荷的一部分，不是构建产物，必须原样带过去。
     */
    private static void mergePayloadAssets(File source, File target) {
        if (source == null || target == null || !source.isFile() || !target.isFile()) return;
        try {
            Map<String, String> env = new HashMap<>();
            env.put("create", "false");
            URI uri = URI.create("jar:" + target.toPath().toAbsolutePath().toUri());
            int added = 0;
            try (java.util.zip.ZipFile src = new java.util.zip.ZipFile(source);
                 java.nio.file.FileSystem zip = java.nio.file.FileSystems.newFileSystem(uri, env)) {
                java.nio.file.Path root = zip.getPath("/");
                java.util.Enumeration<? extends java.util.zip.ZipEntry> en = src.entries();
                while (en.hasMoreElements()) {
                    java.util.zip.ZipEntry entry = en.nextElement();
                    if (entry.isDirectory()) continue;
                    String name = entry.getName();
                    if (name.endsWith(".class") || name.startsWith("META-INF/")
                            || name.equals("classes.dex") || name.endsWith(".dex")) {
                        continue;
                    }
                    java.nio.file.Path out = root.resolve(name);
                    if (java.nio.file.Files.exists(out)) continue;
                    java.nio.file.Path dir = out.getParent();
                    if (dir != null) java.nio.file.Files.createDirectories(dir);
                    try (InputStream in = src.getInputStream(entry)) {
                        java.nio.file.Files.copy(in, out);
                    }
                    added++;
                }
            }
            if (added > 0) {
                System.out.println("[DexSpiderLoader] 补回载荷资源 " + added + " 个 -> " + target.getName());
            }
        } catch (Throwable t) {
            // 补资源失败不该拖死站点：最多是运行期缺 so，交给上层报错
            System.err.println("[DexSpiderLoader] 补回载荷资源失败（忽略）: " + t);
        }
    }

    /** 内置实现（companion classpath 里的 spider，含别名）；找不到返回 null。 */
    private Spider createBuiltin(SpiderRequest r) throws Exception {
        Class<?> builtinClass = findBuiltinSpiderClass(r.cleanApi());
        if (builtinClass == null) return null;
        Object instance = builtinClass.getDeclaredConstructor().newInstance();
        if (instance instanceof Spider) return (Spider) instance;
        return new GenericSpiderWrapper(instance, r.siteKey(), r.ext());
    }

    private boolean hardStop() {
        SpiderAttempt attempt = spiderAttempt.get();
        return Thread.currentThread().isInterrupted() || (attempt != null && attempt.failure != null);
    }

    private void blockAttempt(ParseStage.Failure failure) {
        SpiderAttempt attempt = spiderAttempt.get();
        if (attempt != null && attempt.failure == null) attempt.failure = failure;
    }

    private Spider attemptJar(java.util.concurrent.Callable<Spider> factory) {
        ParseStage.Failure before = ParseStage.current();
        try {
            Spider result = factory.call();
            ParseStage.Failure failure = ParseStage.current();
            // A missing class can legitimately use an explicit builtin alias; a broken implementation cannot.
            if (result == null && failure != null && failure != before && ParseStage.INSTANTIATE.equals(failure.stage)) {
                blockAttempt(failure);
            }
            return result;
        } catch (Throwable error) {
            ParseStage.fail(ParseStage.INSTANTIATE, String.valueOf(error));
            blockAttempt(ParseStage.current());
            return null;
        }
    }

    private ClassLoader acceptJarOutcome(JarOutcome outcome) {
        if (outcome.failure != null) {
            ParseStage.fail(outcome.failure.stage, outcome.failure.detail);
            blockAttempt(outcome.failure);
        } else {
            ParseStage.clearFailure();
        }
        return outcome.loader;
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
        if (!prepareLoader(loader)) return null;

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
        // 类发现命中的载荷与按名加载的同样需要 jar 级初始化，否则载荷静态状态为空
        if (!prepareLoader(loader)) return null;
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
    /**
     * jar 级初始化，每个 loader 只做一次；按名加载与类发现两条路径都必须先经过这里。
     *
     * <p>加固载荷的播放地址是 {@code http://127.0.0.1:<ProxyOrigin 端口>/proxy?...}，手机端由宿主起本地服务；
     * 桌面端必须先把服务起起来：服务先于 init 可用，init 里的 {@code getOwnProxyUrl()} 才有值可取；
     * 即使端口注入失败，服务本身仍活着，载荷的端口探测（9978→10000）仍可能命中。
     */
    private boolean prepareLoader(ClassLoader loader) {
        synchronized (loader) {
            if (PREPARED.contains(loader)) return true;
            GuardProxyServer.ensureStarted(loader);
            // Proxy port injection is advisory: payloads can discover the running proxy themselves.
            ParseStage.clearFailure();
            if (!invokeSpiderJarInit(loader)) {
                blockAttempt(ParseStage.current());
                return false;
            }
            GuardProxyServer.ensureStarted(loader);
            ParseStage.clearFailure();
            PREPARED.add(loader);
            return true;
        }
    }

    private boolean invokeSpiderJarInit(ClassLoader loader) {
        if (!invokeStaticInit(loader, "com.github.catvod.spider.Init")) {
            boolean recovered = invokeStaticInit(loader, "com.github.catvod.spider.InitOrigin");
            if (!recovered && ParseStage.current() != null) return false;
            ParseStage.clearFailure();
            injectGuardHostClass(loader);
            enableGuardHideUtils(loader);
        }
        String payloadInit = PAYLOAD_INIT.get(loader);
        if (payloadInit != null && !invokeStaticInit(loader, payloadInit)) {
            if (ParseStage.current() == null) ParseStage.fail(ParseStage.INIT, "缺少载荷初始化入口: " + payloadInit);
            return false;
        }
        return true;
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
        String alias = rules.alias(cleanApi);
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

        java.util.concurrent.CompletableFuture<JarOutcome> mine = new java.util.concurrent.CompletableFuture<>();
        java.util.concurrent.CompletableFuture<JarOutcome> running = JAR_LOADING.putIfAbsent(jarKey, mine);
        if (running != null) {
            try {
                return acceptJarOutcome(running.get());
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return acceptJarOutcome(new JarOutcome(getClass().getClassLoader(),
                        new ParseStage.Failure(ParseStage.RESOLVE, "等待载荷准备时已中止")));
            } catch (java.util.concurrent.ExecutionException | java.util.concurrent.CancellationException ee) {
                return acceptJarOutcome(new JarOutcome(getClass().getClassLoader(),
                        new ParseStage.Failure(ParseStage.RESOLVE, "载荷准备失败: " + ee)));
            }
        }

        JarOutcome outcome = null;
        try {
            cached = loaders.get(jarKey);
            if (cached != null) {
                outcome = new JarOutcome(cached, null);
            } else {
                JAR_PREP_SLOTS.acquire();
                try {
                    ParseStage.clearFailure();
                    ClassLoader result = createLoader(jarSpec, jarKey);
                    ParseStage.Failure failure = null;
                    if (result == null || result == getClass().getClassLoader()) {
                        failure = ParseStage.current();
                        if (failure == null) failure = new ParseStage.Failure(ParseStage.RESOLVE, "载荷未准备完成");
                    }
                    outcome = new JarOutcome(result != null ? result : getClass().getClassLoader(), failure);
                } finally {
                    JAR_PREP_SLOTS.release();
                }
            }
            return acceptJarOutcome(outcome);
        } catch (Throwable error) {
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            outcome = new JarOutcome(getClass().getClassLoader(),
                    new ParseStage.Failure(ParseStage.RESOLVE, "载荷准备失败: " + error));
            return acceptJarOutcome(outcome);
        } finally {
            // Failure travels with the singleflight result, not with its leader's ThreadLocal.
            mine.complete(outcome != null ? outcome : new JarOutcome(getClass().getClassLoader(),
                    new ParseStage.Failure(ParseStage.RESOLVE, "载荷准备中断")));
            JAR_LOADING.remove(jarKey, mine);
        }
    }

    private ClassLoader createLoader(String jarSpec, String jarKey) {
        // 刚失败过的转换不重试：一次转换是 CPU/IO 重活，失败常在（磁盘、杀软、并发）。
        // 冷却期内直接退回宿主 ClassLoader，具体原因由 ParseStage 记录给体检/日志。
        Long failedAt = jvmJarFailures.get(jarKey);
        if (failedAt != null) {
            long left = JVM_JAR_RETRY_MS - (System.currentTimeMillis() - failedAt);
            if (left > 0) {
                ParseStage.fail(ParseStage.DEX2JAR,
                        "dex→JVM 转换刚失败过，" + (left / 1000 + 1) + "s 后重试: " + jarSpec);
                return getClass().getClassLoader();
            }
            jvmJarFailures.remove(jarKey, failedAt);
        }
        URLClassLoader created;
        try {
            File localJar = resolveJarFile(jarSpec);
            if (localJar == null || !localJar.exists()
                    || (ParseStage.current() != null && ParseStage.DECRYPT.equals(ParseStage.current().stage))) {
                // **失败结果不缓存**：下载/解密可能是暂时性的（网络抖动、首次解密未完成）。
                // 缓存成父加载器会让该 jar 在进程存活期内永远加载不到，表现为「站点一直空白」。
                System.err.println("[DexSpiderLoader] Jar file could not be resolved: " + jarSpec);
                return getClass().getClassLoader();
            }

            File usableJar = ensureJvmJar(localJar);
            // 载荷若声明了 native 库（hardshell profile 的 crypto.*），登记给代调服务；其余 jar 直接忽略。
            com.fongmi.companion.hardshell.PayloadCryptoService.remember(localJar);
            // 静态体检：载荷里若含 ARM-only 原生库（如壳的 libLoadNiMa.so），
            // 依赖它的站点在本机必然是 0 数据。这里只做一次、不阻塞加载。
            try {
                com.fongmi.companion.selfcheck.PayloadInspector.reportOnce(localJar);
            } catch (Throwable ignored) {
            }
            if (usableJar == null) {
                // dex 容器没能转成 JVM jar：不能拿原始 dex 建 ClassLoader（里面没有 .class，
                // 以前这样做还会被缓存住，整站在进程存活期内恒空）。退回宿主、不缓存，冷却后重试。
                // 被看门狗中断导致的失败与载荷无关，不进冷却。
                if (!Thread.currentThread().isInterrupted()) {
                    jvmJarFailures.put(jarKey, System.currentTimeMillis());
                }
                return getClass().getClassLoader();
            }
            created = new URLClassLoader(new URL[]{usableJar.toURI().toURL()}, getClass().getClassLoader());
            String payloadInit = HardshellPipeline.payloadInit(localJar);
            if (payloadInit != null) PAYLOAD_INIT.put(created, payloadInit);
        } catch (Throwable t) {
            if (ParseStage.current() == null) ParseStage.fail(ParseStage.RESOLVE, jarSpec + ": " + t);
            System.err.println("[DexSpiderLoader] Failed to load jar: " + jarSpec + ", err: " + t.getMessage());
            return getClass().getClassLoader();
        }
        loaders.put(jarKey, created);
        return created;
    }

    /**
     * 手机端 spider jar 常为 Android 容器：zip 内只有 classes.dex（无 JVM .class），
     * 由 Android 的 PathClassLoader 直接加载。标准 JVM 无法加载 dex，需要先转换为
     * JVM class jar（dex2jar）。转换结果按源文件 md5 缓存，避免重复转换。
     */
    private File ensureJvmJar(File jarFile) {
        // 同一个产物文件同时只允许一个线程转换；不同 jar 互不阻塞。
        File jvmJar = jvmJarOf(jarFile);
        synchronized (fileLock(jvmJar)) {
            return convertToJvmJar(jarFile, jvmJar);
        }
    }

    /** 转换产物路径：{@code <源名去 .jar>-jvm7<修补链戳>.jar}，放在 cacheDir。 */
    private File jvmJarOf(File jarFile) {
        String base = jarFile.getName();
        if (base.endsWith(".jar")) base = base.substring(0, base.length() - 4);
        // -jvm7：转换器改为 PreciseDex2jar（保留 new-instance 的真实分配类型，不再塌缩成父类）。
        // 旧缓存（-jvm 至 -jvm6）是塌缩产物或基于启发式补点位的产物，直接换名作废。
        // 加固载荷再带上修补链版本戳：修补器升级后旧产物自动作废（普通 jar 戳为空，缓存名不变）。
        String stamp = HardshellPipeline.repairStamp(jarFile);
        return new File(cacheDir, base + "-jvm7" + stamp + ".jar");
    }

    /**
     * 只能在持有 {@code fileLock(jvmJar)} 时调用。转换与后处理都在独占工作目录里做，
     * 全部完成后才原子发布为 {@code jvmJar}：读者只会看到「没有」或「完整」两种状态。
     *
     * @return 可直接加载的 jar（非 dex 容器原样返回）；转换失败返回 null（调用方不缓存）
     */
    private File convertToJvmJar(File jarFile, File jvmJar) {
        File work = null;
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

            if (jvmJar.exists() && jvmJar.length() > 0
                    && jvmJar.lastModified() >= jarFile.lastModified()) {
                return jvmJar;
            }

            System.out.println("[DexSpiderLoader] Converting dex jar to JVM jar: " + jarFile.getName());
            long t0 = System.currentTimeMillis();
            // 每次转换用自己的工作目录。以前所有线程共用同一个 tmp 与正式文件名，
            // 并发 / 中断时互相截断、删除对方产物（日志里的 Dex2jar failed: null）。
            work = newWorkDir(jvmJar.getName());
            File converted = new File(work, jvmJar.getName());
            File tmp = new File(work, "dex2jar.jar");
            PreciseDex2jar.Result result = PreciseDex2jar.convert(jarFile, tmp.toPath());
            if (tmp.exists() && tmp.length() > 0) {
                // 修补 dex2jar 十六进制字符串表还原产生的 arraycopy 反向；
                // 修补失败就退回未修补产物（不影响既有站点）。
                if (!Dex2jarRepair.repair(tmp, converted)) {
                    java.nio.file.Files.move(tmp.toPath(), converted.toPath(),
                            java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                }
                // 载荷里的 assets（.so 等）不是 class，dex2jar 不会带出来，但载荷运行期依赖它们
                // （aowu 的 MyCrypto 要从 assets/awenc-v8.so 加载 native），必须补回。
                mergePayloadAssets(jarFile, converted);
                // 加固载荷的 dex2jar 坍塌按「源声明的修补器链」修；哪些源需要修、
                // 用哪几个修补器，全部由 hardshell 注册表的数据决定，这里不判断源。
                // 未声明修补器的载荷一次都不跑，既有站点行为不变。
                HardshellPipeline.repair(converted, jarFile);
                tmp.delete();
                converted.setLastModified(System.currentTimeMillis());
                publish(converted, jvmJar);
                reportDegradedMethods(jvmJar);
                System.out.println("[DexSpiderLoader] Dex2jar done in " + (System.currentTimeMillis() - t0)
                        + "ms -> " + jvmJar.getName() + " (" + jvmJar.length() + " bytes, "
                        + result.classes + " classes, 保留真实分配类型 " + result.keptMismatchedNew + " 处)");
                return jvmJar;
            }
            ParseStage.fail(ParseStage.DEX2JAR, "dex2jar 输出为空: " + jarFile.getName());
            System.err.println("[DexSpiderLoader] Dex2jar produced empty output for: " + jarFile);
            return null;
        } catch (Throwable t) {
            ParseStage.fail(ParseStage.DEX2JAR, jarFile.getName() + ": " + t);
            // 打印异常本身：并发失败时 getMessage() 常为 null，看不出是哪类错误。
            System.err.println("[DexSpiderLoader] Dex2jar failed: " + t
                    + "（本次不缓存，" + (JVM_JAR_RETRY_MS / 1000) + "s 后重试）");
            return null;
        } finally {
            deleteWork(work);
        }
    }

    /**
     * 转换产物体检：dex2jar 把转不出来的方法降级成「抛异常的桩」，桩里带 {@code d2j: } 原因文本。
     * 这类方法只有运行期被调用才炸（实测表现为 /proxy 500 VerifyError），所以转换完就统计一次，
     * 让日志里能直接看到「这份载荷有多少方法不可用、是哪些类」，不用等用户点播放才暴露。
     */
    private void reportDegradedMethods(File jar) {
        if (jar == null || !jar.isFile()) return;
        java.util.List<String> classes = new java.util.ArrayList<>();
        int hits = 0;
        try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(jar)) {
            java.util.Enumeration<? extends java.util.zip.ZipEntry> en = zip.entries();
            while (en.hasMoreElements()) {
                java.util.zip.ZipEntry e = en.nextElement();
                if (e.isDirectory() || !e.getName().endsWith(".class")) continue;
                byte[] b;
                try (InputStream in = zip.getInputStream(e)) {
                    b = readFully(in);
                }
                if (indexOfStubMarker(b) >= 0) {
                    hits++;
                    if (classes.size() < 8) classes.add(e.getName());
                }
            }
        } catch (Throwable t) {
            return; // 体检失败不影响加载
        }
        if (hits > 0) {
            System.err.println("[DexSpiderLoader] 转换产物含 " + hits + " 个降级桩方法（运行期调用会抛 VerifyError）: "
                    + classes);
        }
    }

    /** 在 class 常量池里找 {@code d2j: } 字面量（降级桩的标志）。只做字节匹配，不解析 class。 */
    private static int indexOfStubMarker(byte[] bytes) {
        byte[] needle = {'d', '2', 'j', ':', ' '};
        outer:
        for (int i = 0; i <= bytes.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (bytes[i + j] != needle[j]) continue outer;
            }
            return i;
        }
        return -1;
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
                // 加固壳：逻辑在 native so 里，需先解出载荷 jar。
                // 这里只查已解包缓存（壳 jar 还没下载），命中即免下载；不区分具体源。
                File shellCached = HardshellPipeline.cached(cacheDir, md5(rawUrl));
                if (shellCached != null) {
                    System.out.println("[DexSpiderLoader] 命中本地加固载荷: " + shellCached.getName());
                    return shellCached;
                }

                String filename = md5(rawUrl) + ".jar";
                File cachedFile = new File(cacheDir, filename);
                if (cachedFile.exists() && cachedFile.length() > 0) {
                    if (expectedMd5.isEmpty() || md5File(cachedFile).equalsIgnoreCase(expectedMd5)) {
                        // 壳已缓存但载荷还没解出来（老版本遗留 / 上次解密失败）→ 就地补解
                        GuardCryptoService.rememberShellJar(cachedFile);
                        File shellPayload = HardshellPipeline.resolve(cacheDir, cachedFile,
                                md5(rawUrl));
                        if (shellPayload != null) return shellPayload;
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

                // 下载到独占临时文件、完成后原子发布。以前多个线程同时往同一个缓存文件
                // Files.copy(REPLACE_EXISTING)，互相截断，表现为 Resolve error / md5 不符 /
                // zip END header not found。
                downloadTo(rawUrl, cachedFile, expectedMd5);
                // 配置里带 ;md5; 就必须核对：否则「配置写错」会拿着一份错误内容一路跑到
                // dex2jar/类加载才炸，定位成本极高（见方案 P1-1 的 md5 阶段）。
                verifyDownloadedMd5(cachedFile, expectedMd5, rawUrl);
                if (!cachedFile.exists() || cachedFile.length() == 0) {
                    return null;
                }
                // 下载完才发现是加固壳：就地自动解密出载荷（首次约 10 s，之后按壳 md5 复用）
                GuardCryptoService.rememberShellJar(cachedFile);
                File shellPayload = HardshellPipeline.resolve(cacheDir, cachedFile, md5(rawUrl));
                if (shellPayload != null) return shellPayload;
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
     * 下载到独占工作目录，完成后原子发布为 {@code target}。按目标文件加锁：等锁的线程
     * 进来时先按缓存命中规则复查，前一个线程刚下好的就不再重下。
     */
    private void downloadTo(String rawUrl, File target, String expectedMd5) throws IOException {
        synchronized (fileLock(target)) {
            if (target.isFile() && target.length() > 0
                    && (expectedMd5.isEmpty() || md5File(target).equalsIgnoreCase(expectedMd5))) {
                return;
            }
            System.out.println("[DexSpiderLoader] Downloading jar from: " + rawUrl);
            File work = newWorkDir(target.getName());
            try {
                File part = new File(work, target.getName());
                URL url = URI.create(rawUrl).toURL();
                java.net.URLConnection conn = url.openConnection();
                conn.setConnectTimeout(15000);
                conn.setReadTimeout(60000);
                try (InputStream in = conn.getInputStream()) {
                    Files.copy(in, part.toPath());
                }
                publish(part, target);
            } finally {
                deleteWork(work);
            }
        }
    }

    private static Object fileLock(File target) {
        return FILE_LOCKS.computeIfAbsent(target.getAbsolutePath(), k -> new Object());
    }

    /** 同卷原子改名；文件系统不支持原子移动时退回普通覆盖。 */
    private static void publish(File done, File target) throws IOException {
        try {
            Files.move(done.toPath(), target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (java.nio.file.AtomicMoveNotSupportedException e) {
            Files.move(done.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
    }

    /** 在 cacheDir 下新建独占工作目录（顺手清掉异常退出留下的旧工作目录）。 */
    private File newWorkDir(String label) throws IOException {
        sweepStaleWork();
        return Files.createTempDirectory(cacheDir.toPath(), WORK_PREFIX + label + "-").toFile();
    }

    /** 工作目录里只有本次写入的普通文件；删不掉的留给下次 {@link #sweepStaleWork}。 */
    private static void deleteWork(File work) {
        if (work == null) return;
        File[] kids = work.listFiles();
        if (kids != null) {
            for (File kid : kids) {
                kid.delete();
            }
        }
        work.delete();
    }

    /**
     * 清理超过 {@link #STALE_WORK_MS} 没有写入的工作目录（进程被杀 / 断电的残留），以及
     * 旧版本固定文件名的转换临时文件。跳过符号链接与目录联接，不跟随。
     */
    private void sweepStaleWork() {
        File[] entries = cacheDir.listFiles();
        if (entries == null) return;
        long cutoff = System.currentTimeMillis() - STALE_WORK_MS;
        for (File entry : entries) {
            String name = entry.getName();
            boolean ours = name.startsWith(WORK_PREFIX);
            boolean legacy = name.contains("-jvm7")
                    && (name.endsWith(".tmp.jar") || name.endsWith(".tmp"));
            if (!ours && !legacy) continue;
            try {
                java.nio.file.attribute.BasicFileAttributes attrs = Files.readAttributes(entry.toPath(),
                        java.nio.file.attribute.BasicFileAttributes.class, java.nio.file.LinkOption.NOFOLLOW_LINKS);
                if (attrs.isSymbolicLink() || attrs.isOther()) continue;
                long newest = attrs.lastModifiedTime().toMillis();
                File[] kids = attrs.isDirectory() ? entry.listFiles() : null;
                if (kids != null) {
                    for (File kid : kids) newest = Math.max(newest, kid.lastModified());
                }
                if (newest >= cutoff) continue;
                if (attrs.isDirectory()) {
                    if (ours) deleteWork(entry);
                } else {
                    entry.delete();
                }
            } catch (Throwable ignored) {
            }
        }
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
