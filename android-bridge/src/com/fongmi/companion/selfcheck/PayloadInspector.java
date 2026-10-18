package com.fongmi.companion.selfcheck;

import java.io.File;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 载荷静态体检：在**不运行**爬虫的前提下，判断一个载荷 jar 在本机是否可能可用。
 *
 * <p>动机：加固壳（wexguard 等）会把 NATIVE 库释放出来交给 {@code System.load}。
 * 如果那是 ARM/AArch64 的 ELF，而当前 JVM 是 x86_64，加载必然抛
 * {@code UnsatisfiedLinkError}，随后整个 native 加载器类初始化失败，
 * 依赖它的站点全部 0 数据——但日志里只会看到一句
 * {@code Could not initialize class ...}，很难判断到底是"源站挂了"还是"架构不兼容"。
 *
 * <p>本类只做两件可静态判断的事：
 * <ol>
 *   <li>遍历 jar 内的原生库条目，读 ELF {@code e_machine}，得出架构集合；</li>
 *   <li>检测是否包含壳的 native 加载器类（如 {@code com/wexfnw/libso/LoadNiMa}）。</li>
 * </ol>
 * 两者结合即可给出"该载荷是纯 Java 可用 / 需要 ARM / 完全兼容"的结论，
 * 并且同一份载荷只打印一次，避免每个站点刷一行。
 */
public final class PayloadInspector {

    /** ELF e_machine -> 架构名。 */
    private static final Map<Integer, String> ELF_ARCH = new LinkedHashMap<>();

    static {
        ELF_ARCH.put(3, "x86");
        ELF_ARCH.put(8, "mips");
        ELF_ARCH.put(20, "ppc");
        ELF_ARCH.put(21, "ppc64");
        ELF_ARCH.put(40, "arm");
        ELF_ARCH.put(62, "x86_64");
        ELF_ARCH.put(183, "aarch64");
        ELF_ARCH.put(243, "riscv");
    }

    /** 壳的 native 加载器类前缀：命中即说明业务代码会走 native 路径。 */
    private static final String[] NATIVE_LOADER_MARKERS = {
            "com/wexfnw/libso/",
    };

    /** 已经报告过的载荷（按绝对路径），保证一次进程只打印一次。 */
    private static final Set<String> REPORTED = ConcurrentHashMap.newKeySet();

    /**
     * 体检总开关。默认关闭：体检属于排查手段，会为每个载荷做一次 zip 扫描
     * 并写诊断日志；只有用户在设置里显式开启后才有意义。
     * 由 {@code Main} 的 {@code --self-check=on|off} 初始配置，并可由
     * {@code SpiderServer} 的 {@code selfCheckConfig} 调用在运行期改写。
     */
    private static volatile boolean enabled = false;

    private PayloadInspector() {
    }

    /** 运行期开关：关闭时 {@link #reportOnce(File)} 直接返回，不扫描也不打印。 */
    public static void setEnabled(boolean value) {
        enabled = value;
    }

    public static boolean isEnabled() {
        return enabled;
    }

    /** 体检结果。 */
    public static final class Report {
        public String jar = "";
        /** 架构 -> 该架构的原生库文件名列表。 */
        public final Map<String, List<String>> natives = new LinkedHashMap<>();
        /** 是否存在壳的 native 加载器类。 */
        public boolean hasNativeLoader;
        /** 命中的加载器类名（便于在日志里指名道姓）。 */
        public final List<String> loaderClasses = new ArrayList<>();
        /** 载荷内的 Guard 爬虫类数量（对齐 csp_XxxGuard 的分布）。 */
        public int guardClasses;
        /** 当前 JVM 架构。 */
        public String jvmArch = currentJvmArch();
        /** 是否与当前 JVM 兼容：无原生库，或原生库包含当前架构。 */
        public boolean compatible = true;

        /** 一句话结论，可直接写日志。 */
        public String summary() {
            StringBuilder sb = new StringBuilder();
            sb.append("[SelfCheck] 载荷 ").append(shortName(jar));
            sb.append(" | JVM=").append(jvmArch);
            if (natives.isEmpty()) {
                sb.append(" | 无原生库");
            } else {
                sb.append(" | native=");
                boolean first = true;
                for (Map.Entry<String, List<String>> e : natives.entrySet()) {
                    if (!first) sb.append(", ");
                    first = false;
                    sb.append(e.getKey()).append('x').append(e.getValue().size());
                }
            }
            if (hasNativeLoader) {
                sb.append(" | 含 native 加载器=").append(loaderClasses.isEmpty() ? "?" : loaderClasses.get(0));
            }
            sb.append(" | Guard类=").append(guardClasses);
            sb.append(" | ").append(compatible ? "架构兼容" : "架构不兼容（ARM-only）");
            return sb.toString();
        }

        /** 预测：本载荷能直接跑的站点比例大概率是多少。 */
        public String prediction() {
            if (!compatible) {
                return "预测：依赖 native 的站点会整站 0 数据（需逐站确认，纯 Java 站点仍可能可用）";
            }
            if (hasNativeLoader) {
                return "预测：含 native 加载器但架构兼容，多数站点应可用";
            }
            return "预测：纯 Java/兼容载荷，站点应可用";
        }

        public String toJson() {
            StringBuilder sb = new StringBuilder();
            sb.append('{');
            sb.append("\"jar\":\"").append(escape(jar)).append("\",");
            sb.append("\"jvmArch\":\"").append(escape(jvmArch)).append("\",");
            sb.append("\"compatible\":").append(compatible).append(',');
            sb.append("\"hasNativeLoader\":").append(hasNativeLoader).append(',');
            sb.append("\"guardClasses\":").append(guardClasses).append(',');
            sb.append("\"natives\":{");
            boolean first = true;
            for (Map.Entry<String, List<String>> e : natives.entrySet()) {
                if (!first) sb.append(',');
                first = false;
                sb.append('"').append(escape(e.getKey())).append("\":[");
                for (int i = 0; i < e.getValue().size(); i++) {
                    if (i > 0) sb.append(',');
                    sb.append('"').append(escape(e.getValue().get(i))).append('"');
                }
                sb.append(']');
            }
            sb.append("},");
            sb.append("\"loaderClasses\":[");
            for (int i = 0; i < loaderClasses.size(); i++) {
                if (i > 0) sb.append(',');
                sb.append('"').append(escape(loaderClasses.get(i))).append('"');
            }
            sb.append("]}");
            return sb.toString();
        }
    }

    /** 体检一个 jar（壳 jar、解密后的 payload jar、dex2jar 产物都可以）。 */
    public static Report inspect(File jar) {
        Report r = new Report();
        if (jar == null || !jar.isFile()) {
            return r;
        }
        r.jar = jar.getAbsolutePath();
        Set<String> seenNativeArch = new LinkedHashSet<>();
        try (ZipFile zip = new ZipFile(jar)) {
            java.util.Enumeration<? extends ZipEntry> it = zip.entries();
            while (it.hasMoreElements()) {
                ZipEntry entry = it.nextElement();
                if (entry.isDirectory()) {
                    continue;
                }
                String name = entry.getName();
                String lower = name.toLowerCase(Locale.ROOT);

                // 1) 原生库：assets/*.so、libs/*/*.so、运行期释放的 .libLoadNiMa*
                boolean looksNative = lower.endsWith(".so") || lower.contains("libloadnima");
                if (looksNative) {
                    String arch = elfArch(zip, entry);
                    if (arch != null) {
                        r.natives.computeIfAbsent(arch, k -> new ArrayList<>()).add(name);
                        seenNativeArch.add(arch);
                    }
                }

                // 2) 壳的 native 加载器类
                for (String marker : NATIVE_LOADER_MARKERS) {
                    if (lower.startsWith(marker.toLowerCase(Locale.ROOT)) && lower.endsWith(".class")) {
                        r.hasNativeLoader = true;
                        String cls = name.substring(0, name.length() - 6).replace('/', '.');
                        if (!r.loaderClasses.contains(cls)) {
                            r.loaderClasses.add(cls);
                        }
                        break;
                    }
                }

                // 3) Guard 爬虫类计数
                if (lower.startsWith("com/github/catvod/spider/") && lower.endsWith(".class")) {
                    String simple = name.substring(name.lastIndexOf('/') + 1, name.length() - 6);
                    if (simple.endsWith("Guard")) {
                        r.guardClasses++;
                    }
                }
            }
        } catch (Throwable t) {
            // 损坏/非 zip：当作空报告，不打断调用方
        }

        r.compatible = r.natives.isEmpty() || seenNativeArch.contains(r.jvmArch);
        return r;
    }

    /** 同一份载荷只打印一次；返回是否本次真的打印了。 */
    public static boolean reportOnce(File jar) {
        if (!enabled) {
            return false;
        }
        if (jar == null) {
            return false;
        }
        String key = jar.getAbsolutePath();
        if (!REPORTED.add(key)) {
            return false;
        }
        Report r = inspect(jar);
        // 解密后的 payload 是纯 dex（没有 .so、没有 .class），查不出任何信息，
        // 打印出来只是噪音。只有具备"可判断特征"的载荷才值得说一句。
        if (r.natives.isEmpty() && !r.hasNativeLoader && r.guardClasses == 0) {
            return false;
        }
        System.out.println(r.summary());
        System.out.println(r.prediction());
        return true;
    }

    /** 当前 JVM 架构，统一成 ELF 命名（x86_64 / aarch64 / ...）。 */
    public static String currentJvmArch() {
        String arch = System.getProperty("os.arch", "").toLowerCase(Locale.ROOT);
        switch (arch) {
            case "amd64":
            case "x86_64":
            case "x64":
                return "x86_64";
            case "aarch64":
            case "arm64":
                return "aarch64";
            case "x86":
            case "i386":
            case "i686":
                return "x86";
            case "arm":
                return "arm";
            default:
                return arch.isEmpty() ? "unknown" : arch;
        }
    }

    /** 读 ELF 头取 e_machine；非 ELF 返回 null。 */
    private static String elfArch(ZipFile zip, ZipEntry entry) {
        try (InputStream in = zip.getInputStream(entry)) {
            byte[] head = new byte[20];
            int off = 0;
            while (off < head.length) {
                int n = in.read(head, off, head.length - off);
                if (n < 0) break;
                off += n;
            }
            if (off < 20) return null;
            if ((head[0] & 0xff) != 0x7f || head[1] != 'E' || head[2] != 'L' || head[3] != 'F') {
                return null;
            }
            boolean littleEndian = (head[5] & 0xff) == 1;
            int b0 = head[18] & 0xff;
            int b1 = head[19] & 0xff;
            int machine = littleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1);
            String name = ELF_ARCH.get(machine);
            return name != null ? name : ("elf-" + machine);
        } catch (Throwable t) {
            return null;
        }
    }

    private static String shortName(String path) {
        if (path == null || path.isEmpty()) return "?";
        int i = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return i >= 0 ? path.substring(i + 1) : path;
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
