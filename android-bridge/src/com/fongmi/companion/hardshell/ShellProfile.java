package com.fongmi.companion.hardshell;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;

/**
 * 一类加固壳的完整形态描述。**纯数据**：新增一个源 = 新增一条 profile（可来自
 * {@code hardshell-<id>.properties} 文件，不必改 Java）。
 *
 * <h3>两级形态</h3>
 * 加固源在磁盘上总是两副面孔，判定只看 jar 内条目，不依赖外部状态：
 * <ul>
 *   <li><b>壳容器</b>（{@link #shellMarkers}）：配置里下载到的那个 jar，只有
 *       {@code classes.dex} + 一个加密载荷资源。它自己不实现抓取，所有 csp_* 类都是转发壳。</li>
 *   <li><b>解密载荷</b>（{@link #payloadMarkers}）：native 解包产物，是可直接 dex2jar 的普通 jar。
 *       它同时充当"解包成功"的验收条件——不靠退出码，靠产物自身证据。</li>
 * </ul>
 *
 * <h3>字段分组</h3>
 * 前两组决定"是不是这个壳"，中间两组决定"怎么拿到载荷"，最后几项只影响模拟细节。
 * 没有任何字段与源的业务语义绑定，因此同一个 profile 可服务同族的所有站点。
 */
public final class ShellProfile {

    /** 短标识：缓存文件名前缀、日志、子进程 {@code --id} 参数都用它。 */
    public final String id;
    /** 人类可读名（日志用）。 */
    public final String displayName;

    /** 壳容器特征条目（任一命中即判定为壳容器）。 */
    public final String[] shellMarkers;
    /** 解密载荷特征条目（任一命中即视为合格载荷）。 */
    public final String[] payloadMarkers;

    /**
     * 索引地址。响应里含 {@code {md5,url}} 时按索引模式处理；
     * 留空则从壳自身 dex 字面量自动发现（见 {@link #discoverIndexUrls}）。
     */
    public final String[] indexUrls;
    /** 容器直链（跳过索引）。与 {@link #indexUrls} 二选一。 */
    public final String[] containerUrls;

    /** 容器内 native 库候选名，首个按 64 位优先，其余为回退（32 位）。 */
    public final String[] soNames;
    /**
     * 该壳载荷需要的 dex2jar 坍塌修补器 id（见 {@link PayloadRepair}）。
     * 留空表示不跑修补链——既有站点不声明此项，因此行为与改动前完全一致。
     */
    public final String[] repairIds;

    /** 容器内加密载荷条目。 */
    public final String payloadEntry;
    /** 壳解包后写出的文件名（在 guest cacheDir 里）。 */
    public final String decryptedName;

    /** 子进程入口类名。**必须是字符串**，见 {@link NativeProvisioner} 注释。 */
    public final String unwrapMain;
    /** 子进程超时。 */
    public final long unwrapTimeoutMs;

    /** unidbg 侧环境参数。 */
    public final String guestBase;
    public final String packageName;
    /** 壳注册 native 方法的类（JNI 入口）。 */
    public final String nativeClass;
    /** 触发解包的方法签名。 */
    public final String unwrapSignature;

    /**
     * 载荷侧 native 库在载荷 jar 内的条目（64 位优先）。载荷的 Java 类只声明 native，
     * 真正的实现由该库在 {@code JNI_OnLoad} 里 {@code RegisterNatives}；留空表示该载荷无 native 依赖。
     */
    public final String[] cryptoSo;
    /**
     * 载荷自己的初始化入口类（静态 {@code init(Context)}）。手机上由壳的 {@code Init} 转调；
     * 桌面端直接加载解密载荷，绕过了壳，必须由加载器补调，否则载荷里依赖它的静态状态全是 null。
     */
    public final String payloadInit;
    /** 载荷 native 方法所属的类（JNI 名或点分名均可）。 */
    public final String cryptoClass;
    /**
     * 载荷库加载前必须存在的环境变量（{@code KEY=VALUE}）。真机上它们由壳库在同一进程里
     * {@code setenv} 留下；桌面端壳与载荷分属两个模拟器，缺了库会直接 {@code exit_group}。
     */
    public final String[] cryptoEnv;

    private ShellProfile(Builder b) {
        this.id = b.id;
        this.displayName = b.displayName == null ? b.id : b.displayName;
        this.shellMarkers = b.shellMarkers.toArray(new String[0]);
        this.payloadMarkers = b.payloadMarkers.toArray(new String[0]);
        this.indexUrls = b.indexUrls.toArray(new String[0]);
        this.containerUrls = b.containerUrls.toArray(new String[0]);
        this.soNames = b.soNames.toArray(new String[0]);
        this.repairIds = b.repairIds.toArray(new String[0]);
        this.payloadEntry = b.payloadEntry;
        this.decryptedName = b.decryptedName;
        this.unwrapMain = b.unwrapMain;
        this.unwrapTimeoutMs = b.unwrapTimeoutMs;
        this.guestBase = b.guestBase;
        this.packageName = b.packageName;
        this.nativeClass = b.nativeClass;
        this.unwrapSignature = b.unwrapSignature;
        this.payloadInit = b.payloadInit;
        this.cryptoSo = b.cryptoSo.toArray(new String[0]);
        this.cryptoClass = b.cryptoClass;
        this.cryptoEnv = b.cryptoEnv.toArray(new String[0]);
    }

    /** 是否具备完整的解包能力（缺一项就只能识别、不能解包）。 */
    public boolean canUnwrap() {
        return soNames.length > 0
                && !JarIndex.isEmpty(payloadEntry)
                && !JarIndex.isEmpty(decryptedName)
                && !JarIndex.isEmpty(unwrapMain);
    }

    /** 载荷是否声明了可托管的 native 库。 */
    public boolean hasCrypto() {
        return cryptoSo.length > 0 && !JarIndex.isEmpty(cryptoClass);
    }

    /** 是否为该壳的容器。 */
    public boolean isShell(java.io.File jar) {
        return JarIndex.firstHit(jar, shellMarkers) != null;
    }

    /** 是否为该壳的解密载荷。 */
    public boolean isPayload(java.io.File jar) {
        return JarIndex.firstHit(jar, payloadMarkers) != null;
    }

    /**
     * 未显式配置索引地址时的自动发现：把 dex 里的 URL 前缀，与壳自身资产名拼起来。
     *
     * <p>壳的下载地址普遍是「基址 + 名字」两段存储（实测基址 {@code https://host/} 与
     * 资产名 {@code assets/<name>.bin} 分开），所以把资产名去扩展名后逐一尝试拼接，
     * 即可在**不看任何源特有代码**的情况下还原出候选索引地址。
     *
     * @param shellJar 壳 jar
     * @param limit    最多返回几个候选
     */
    public List<String> discoverIndexUrls(java.io.File shellJar, int limit) {
        List<String> out = new ArrayList<>();
        if (indexUrls.length > 0) {
            for (String u : indexUrls) out.add(u);
            return out;
        }
        List<String> bases = JarIndex.dexUrls(shellJar);
        if (bases.isEmpty()) return out;
        List<String> tokens = markerTokens();
        for (String base : bases) {
            String b = base.endsWith("/") ? base : base + "/";
            for (String t : tokens) {
                String candidate = b + t;
                if (!out.contains(candidate)) out.add(candidate);
                if (out.size() >= limit) return out;
            }
            // 基址本身就是完整地址的形态（dex 里已含路径）
            if (tokens.isEmpty() && !out.contains(base)) out.add(base);
        }
        return out;
    }

    /** 从壳特征条目名里取出候选路径片段（{@code assets/woshinidie.bin} → {@code woshinidie}）。 */
    private List<String> markerTokens() {
        List<String> out = new ArrayList<>();
        for (String m : shellMarkers) {
            int slash = m.lastIndexOf('/');
            String name = slash >= 0 ? m.substring(slash + 1) : m;
            int dot = name.lastIndexOf('.');
            if (dot > 0) name = name.substring(0, dot);
            if (name.length() >= 3 && !out.contains(name)) out.add(name);
        }
        return out;
    }

    // ------------------------------------------------------------------ 从 properties 构建

    /**
     * 从 properties 构建。
     *
     * <p>键名（全部可选，除 {@code id} 与 {@code shell.markers}）：
     * <pre>
     *   id=moyuer
     *   name=摸鱼儿
     *   shell.markers=assets/xxx.bin,assets/yyy.dat
     *   payload.markers=assets/enc-v8.so
     *   index.urls=https://example.com/index
     *   container.urls=https://example.com/container.jar
     *   so.names=xxx-v8.so;xxx-v7.so
     *   repair.ids=ctor-inline
     *   payload.entry=payload.amns
     *   decrypted.name=out.db
     *   guest.base=/data/local/tmp/hardshell
     *   pkg=com.fongmi.android.tv
     *   native.class=com.github.catvod.spider.DexNative
     *   native.sig=getLoader(Ljava/lang/Object;Ljava/io/InputStream;)Ljava/lang/Object;
     *   timeout.ms=120000
     *   payload.init=com.github.catvod.spider.XxxInit
     *   crypto.so=assets/enc-v8.so;assets/enc-v7.so
     *   crypto.class=com.github.catvod.spider.MyCrypto
     *   crypto.env=KEY=VALUE;KEY2=VALUE2
     * </pre>
     */
    public static ShellProfile from(Properties p, String fallbackId) {
        Builder b = new Builder();
        b.id = p.getProperty("id", fallbackId);
        b.displayName = p.getProperty("name", b.id);
        b.shellMarkers = list(p.getProperty("shell.markers"), "[,;\\s]+");
        b.payloadMarkers = list(p.getProperty("payload.markers"), "[,;\\s]+");
        b.indexUrls = list(p.getProperty("index.urls"), "[,;\\s]+");
        b.containerUrls = list(p.getProperty("container.urls"), "[,;\\s]+");
        b.soNames = list(p.getProperty("so.names"), ";");
        b.repairIds = list(p.getProperty("repair.ids"), "[,;\\s]+");
        b.payloadEntry = p.getProperty("payload.entry");
        b.decryptedName = p.getProperty("decrypted.name");
        b.unwrapMain = p.getProperty("unwrap.main",
                NativeProvisioner.DEFAULT_UNWRAP_MAIN);
        b.unwrapTimeoutMs = longOf(p.getProperty("timeout.ms"), 120_000L);
        b.guestBase = p.getProperty("guest.base", "/data/local/tmp/hardshell");
        b.packageName = p.getProperty("pkg", "com.fongmi.android.tv");
        b.nativeClass = p.getProperty("native.class", "com.github.catvod.spider.DexNative");
        b.unwrapSignature = p.getProperty("native.sig",
                "getLoader(Ljava/lang/Object;Ljava/io/InputStream;)Ljava/lang/Object;");
        b.payloadInit = p.getProperty("payload.init");
        b.cryptoSo = list(p.getProperty("crypto.so"), "[,;\s]+");
        b.cryptoClass = p.getProperty("crypto.class");
        b.cryptoEnv = list(p.getProperty("crypto.env"), ";");
        return new ShellProfile(b);
    }

    private static List<String> list(String raw, String sepRegex) {
        List<String> out = new ArrayList<>();
        if (JarIndex.isEmpty(raw)) return out;
        for (String s : raw.split(sepRegex)) {
            String t = s.trim();
            if (!t.isEmpty() && !out.contains(t)) out.add(t);
        }
        return out;
    }

    private static long longOf(String raw, long def) {
        try {
            return raw == null ? def : Long.parseLong(raw.trim());
        } catch (Throwable ignored) {
            return def;
        }
    }

    @Override
    public String toString() {
        StringBuilder b = new StringBuilder(id);
        if (shellMarkers.length > 0) b.append(" shell=").append(String.join("|", shellMarkers));
        if (payloadMarkers.length > 0) b.append(" payload=").append(String.join("|", payloadMarkers));
        return b.toString();
    }

    /** 缓存文件名前缀：profile id 小写，避免与别的壳互换产物。 */
    public String cachePrefix() {
        return id.toLowerCase(Locale.ROOT);
    }

    /** 构造器：内置条目与 properties 共用。 */
    public static final class Builder {
        String id;
        String displayName;
        List<String> shellMarkers = new ArrayList<>();
        List<String> payloadMarkers = new ArrayList<>();
        List<String> indexUrls = new ArrayList<>();
        List<String> containerUrls = new ArrayList<>();
        List<String> soNames = new ArrayList<>();
        List<String> repairIds = new ArrayList<>();
        String payloadEntry;
        String decryptedName;
        String unwrapMain = NativeProvisioner.DEFAULT_UNWRAP_MAIN;
        long unwrapTimeoutMs = 120_000L;
        String guestBase = "/data/local/tmp/hardshell";
        String packageName = "com.fongmi.android.tv";
        String nativeClass = "com.github.catvod.spider.DexNative";
        String unwrapSignature = "getLoader(Ljava/lang/Object;Ljava/io/InputStream;)Ljava/lang/Object;";
        String payloadInit;
        List<String> cryptoSo = new ArrayList<>();
        String cryptoClass;
        List<String> cryptoEnv = new ArrayList<>();

        public Builder id(String v) {
            this.id = v;
            return this;
        }

        public Builder displayName(String v) {
            this.displayName = v;
            return this;
        }

        public Builder shellMarkers(String... v) {
            for (String s : v) if (s != null) this.shellMarkers.add(s);
            return this;
        }

        public Builder payloadMarkers(String... v) {
            for (String s : v) if (s != null) this.payloadMarkers.add(s);
            return this;
        }

        public Builder indexUrls(String... v) {
            for (String s : v) if (s != null) this.indexUrls.add(s);
            return this;
        }

        public Builder containerUrls(String... v) {
            for (String s : v) if (s != null) this.containerUrls.add(s);
            return this;
        }

        public Builder soNames(String... v) {
            for (String s : v) if (s != null) this.soNames.add(s);
            return this;
        }

        public Builder repairIds(String... v) {
            for (String s : v) if (s != null) this.repairIds.add(s);
            return this;
        }

        public Builder payloadEntry(String v) {
            this.payloadEntry = v;
            return this;
        }

        public Builder decryptedName(String v) {
            this.decryptedName = v;
            return this;
        }

        public Builder unwrapMain(String v) {
            if (v != null) this.unwrapMain = v;
            return this;
        }

        public Builder unwrapTimeoutMs(long v) {
            if (v > 0) this.unwrapTimeoutMs = v;
            return this;
        }

        public Builder guestBase(String v) {
            if (v != null) this.guestBase = v;
            return this;
        }

        public Builder packageName(String v) {
            if (v != null) this.packageName = v;
            return this;
        }

        public Builder nativeClass(String v) {
            if (v != null) this.nativeClass = v;
            return this;
        }

        public Builder unwrapSignature(String v) {
            if (v != null) this.unwrapSignature = v;
            return this;
        }

        public Builder payloadInit(String v) {
            this.payloadInit = v;
            return this;
        }

        public Builder cryptoSo(String... v) {
            for (String s : v) if (s != null) this.cryptoSo.add(s);
            return this;
        }

        public Builder cryptoClass(String v) {
            this.cryptoClass = v;
            return this;
        }

        public Builder cryptoEnv(String... v) {
            for (String s : v) if (s != null) this.cryptoEnv.add(s);
            return this;
        }

        public ShellProfile build() {
            if (JarIndex.isEmpty(id)) throw new IllegalArgumentException("profile 缺 id");
            return new ShellProfile(this);
        }

        /** 当前已登记的 id → 字段名，便于诊断日志。 */
        Map<String, String> describe() {
            Map<String, String> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("shellMarkers", String.join("|", shellMarkers));
            m.put("payloadMarkers", String.join("|", payloadMarkers));
            return m;
        }
    }
}
