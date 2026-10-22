package com.fongmi.companion.guard;

import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.AndroidEmulatorBuilder;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.AbstractJni;
import com.github.unidbg.linux.android.dvm.DalvikModule;
import com.github.unidbg.linux.android.dvm.DvmClass;
import com.github.unidbg.linux.android.dvm.DvmObject;
import com.github.unidbg.linux.android.dvm.StringObject;
import com.github.unidbg.linux.android.dvm.VM;
import com.github.unidbg.linux.android.dvm.array.IntArray;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 加固壳的「常驻解密服务」：把安卓端 libftyguard.so 的加解密能力原样搬到桌面。
 *
 * <p>为什么需要它：
 * <ul>
 *   <li>{@code HideUtils} 的四个方法在手机端由壳的 ARM so 实现，桌面端此前只有 Java 近似
 *       （{@link com.fongmi.companion.GuardHost} 的 EXT_MAP 只能覆盖已经离线解过的密文）；</li>
 *   <li>ext 换一批、或换一个配置源，就会出现「表里没有 → 返回原密文 → 站点 0 条」；</li>
 *   <li>壳的 {@code native_ting_md5} 并非标准 MD5，Java 近似算法本身就是错的。</li>
 * </ul>
 *
 * <p>做法：复用 {@link GuardDecryptor} 已验证的 unidbg 初始化（同一套 so、同一套依赖），
 * 但**不跑 getLoader**，直接调用壳 dex 里 {@code com.github.catvod.spider.DexNative} 的
 * 四个普通命名 native 方法。实测当前代壳 2 秒内可用，且不依赖任何混淆方法名。
 *
 * <p>两种运行形态：
 * <pre>
 *   GuardCryptoService &lt;shellJar&gt; --serve     // 服务端：stdin/stdout 上的 base64 协议
 *   GuardCryptoService.decrypt/encrypt/...      // 客户端：懒启动子进程、超时、失败熔断
 * </pre>
 *
 * <p>这是**可选增强**：服务不可用（缺 lib-unidbg、无壳 jar、启动失败）时，客户端一律返回
 * {@code null}，上层继续用 EXT_MAP/恒等兜底，不会把站点拖死。
 */
public final class GuardCryptoService {

    /** 客户端请求超时：单次 native 调用实测 &lt; 100ms，留足余量。 */
    private static final long CALL_TIMEOUT_MS = 15_000;
    /** 子进程启动超时：unidbg 冷启动实测约 2s，慢盘/杀软下留足余量。 */
    private static final long START_TIMEOUT_MS = 60_000;
    /** 连续失败多少次后熔断（避免每个站点都白等一次超时）。 */
    private static final int MAX_FAILURES = 2;
    /** 熔断恢复时间。 */
    private static final long COOLDOWN_MS = 5 * 60_000L;

    private GuardCryptoService() {
    }

    // ==================================================================================
    // 服务端（子进程）
    // ==================================================================================

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: GuardCryptoService <shellJar> [--serve]");
            System.exit(2);
            return;
        }
        File shellJar = new File(args[0]);
        if (!shellJar.isFile() || shellJar.length() == 0) {
            System.err.println("[GuardCrypto] shell jar not found: " + shellJar);
            System.exit(3);
            return;
        }
        boolean serve = args.length > 1 && "--serve".equals(args[1]);
        ShellCrypto crypto = new ShellCrypto(shellJar);
        if (!serve) {
            String probe = args.length > 2 ? args[2] : "";
            System.out.println(crypto.decrypt(probe));
            return;
        }
        serve(crypto);
    }

    private static void serve(ShellCrypto crypto) throws Exception {
        // 协议全部是 ASCII（base64），不受 Windows 控制台 GBK 影响。
        PrintStream out = new PrintStream(new FileOutputStream(java.io.FileDescriptor.out), true, "UTF-8");
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        System.err.println("[GuardCrypto] ready, shell=" + crypto.shellJar.getName());
        out.println("READY");
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty()) continue;
            if ("QUIT".equals(line)) break;
            int tab = line.indexOf('\t');
            String op = tab < 0 ? line : line.substring(0, tab);
            String payload = tab < 0 ? "" : line.substring(tab + 1);
            try {
                switch (op) {
                    case "PING":
                        out.println("OK\t" + b64("pong"));
                        break;
                    case "DECRYPT":
                        write(out, crypto.decrypt(unb64(payload)));
                        break;
                    case "ENCRYPT":
                        write(out, crypto.encrypt(unb64(payload)));
                        break;
                    case "MD5":
                        write(out, crypto.tingMd5(unb64(payload)));
                        break;
                    case "CALC":
                        writeCalc(out, crypto.calcResult(parseInts(unb64(payload))));
                        break;
                    default:
                        out.println("ERR\t" + b64("unknown op: " + op));
                }
            } catch (Throwable t) {
                out.println("ERR\t" + b64(String.valueOf(t)));
            }
        }
        out.flush();
    }

    private static void write(PrintStream out, String value) {
        out.println(value == null ? "NIL" : "OK\t" + b64(value));
    }

    private static void writeCalc(PrintStream out, int[] value) {
        if (value == null) {
            out.println("NIL");
            return;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < value.length; i++) {
            if (i > 0) sb.append(',');
            sb.append(value[i]);
        }
        out.println("OK\t" + b64(sb.toString()));
    }

    /**
     * 一个壳实例的 native 加密能力。
     *
     * <p>只做三件事：解出 so、起 unidbg、调 {@code DexNative}。刻意不触发
     * {@code getLoader}（那条路需要完整的 Java IO 桥，见 {@link GuardDecryptor}），
     * 因为加解密 native 不依赖壳的载荷还原流程。
     */
    private static final class ShellCrypto {

        final File shellJar;
        private final AndroidEmulator emulator;
        private final VM vm;
        private final DvmClass dexNative;

        ShellCrypto(File shellJar) throws Exception {
            this.shellJar = shellJar;
            File tmp = Files.createTempDirectory("guardcrypto-").toFile();
            tmp.deleteOnExit();
            File so = extractSo(shellJar, tmp);
            if (so == null) throw new IOException("no guard so in shell jar: " + shellJar.getName());
            this.emulator = AndroidEmulatorBuilder.for64Bit()
                    .setProcessName("com.fongmi.android.tv")
                    .build();
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
            this.vm = emulator.createDalvikVM(shellJar);
            vm.setJni(new AbstractJni() {
            });
            vm.setVerbose(Boolean.getBoolean("guardcrypto.verbose"));
            DalvikModule module = vm.loadLibrary(so, true);
            module.callJNI_OnLoad(emulator);
            this.dexNative = vm.resolveClass("com.github.catvod.spider.DexNative");
        }

        String decrypt(String s) {
            return stringCall("decrypt(Ljava/lang/String;)Ljava/lang/String;", s);
        }

        String encrypt(String s) {
            return stringCall("encrypt(Ljava/lang/String;)Ljava/lang/String;", s);
        }

        String tingMd5(String s) {
            return stringCall("native_ting_md5(Ljava/lang/String;)Ljava/lang/String;", s);
        }

        int[] calcResult(int[] arr) {
            if (arr == null) return null;
            DvmObject<?> result = dexNative.callStaticJniMethodObject(emulator,
                    "calcResult([I)[I", new IntArray(vm, arr));
            Object value = result == null ? null : result.getValue();
            return value instanceof int[] ? (int[]) value : null;
        }

        private String stringCall(String signature, String arg) {
            if (arg == null) return null;
            DvmObject<?> result = dexNative.callStaticJniMethodObject(emulator, signature,
                    new StringObject(vm, arg));
            Object value = result == null ? null : result.getValue();
            return value == null ? null : String.valueOf(value);
        }
    }

    private static File extractSo(File shellJar, File tmp) throws IOException {
        String[] candidates = {
                "assets/ftyguard_v8.so", "assets/ftyguard_v7.so",
                "assets/wexguard_v8.so", "assets/wexguard_v7.so",
        };
        try (ZipFile zip = new ZipFile(shellJar)) {
            for (String name : candidates) {
                ZipEntry entry = zip.getEntry(name);
                if (entry == null || entry.getSize() == 0) continue;
                File out = new File(tmp, new File(name).getName());
                try (InputStream in = zip.getInputStream(entry)) {
                    Files.copy(in, out.toPath());
                }
                return out;
            }
        }
        return null;
    }

    // ==================================================================================
    // 客户端（companion 进程内）
    // ==================================================================================

    private static final Object LOCK = new Object();
    private static volatile File shellJar;
    private static Process process;
    private static BufferedWriter toServer;
    private static BufferedReader fromServer;
    private static int failures;
    private static long cooldownUntil;

    /** 记录当前配置对应的壳 jar；换壳时自动重启服务。 */
    public static void rememberShellJar(File jar) {
        if (jar == null || !jar.isFile()) return;
        File current = shellJar;
        if (current != null && current.getAbsolutePath().equals(jar.getAbsolutePath())) return;
        synchronized (LOCK) {
            if (process != null) stopLocked();
            shellJar = jar;
            failures = 0;
            cooldownUntil = 0;
        }
    }

    /**
     * 解密模式：
     * <ul>
     *   <li>{@code auto}（默认）：EXT_MAP 命中就用表，未命中才问壳；</li>
     *   <li>{@code service}：优先问壳，失败再回落表 —— 用于验证两者是否一致；</li>
     *   <li>{@code map} / {@code off}：完全禁用壳服务，回到纯 Java 近似。</li>
     * </ul>
     */
    public static String mode() {
        String value = System.getProperty("xiugou.guard.crypto", "auto");
        return value == null ? "auto" : value.trim().toLowerCase(Locale.ROOT);
    }

    public static boolean serviceDisabled() {
        String mode = mode();
        return "map".equals(mode) || "off".equals(mode);
    }

    public static String decrypt(String s) {
        return request("DECRYPT", s);
    }

    public static String encrypt(String s) {
        return request("ENCRYPT", s);
    }

    public static String tingMd5(String s) {
        return request("MD5", s);
    }

    public static int[] calcResult(int[] arr) {
        if (arr == null || serviceDisabled()) return null;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < arr.length; i++) {
            if (i > 0) sb.append(',');
            sb.append(arr[i]);
        }
        String raw = request("CALC", sb.toString());
        if (raw == null) return null;
        String[] parts = raw.split(",");
        List<Integer> values = new ArrayList<>(parts.length);
        for (String part : parts) {
            String text = part.trim();
            if (text.isEmpty()) continue;
            try {
                values.add(Integer.parseInt(text));
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        int[] result = new int[values.size()];
        for (int i = 0; i < result.length; i++) result[i] = values.get(i);
        return result;
    }

    private static String request(String op, String arg) {
        if (arg == null || serviceDisabled()) return null;
        synchronized (LOCK) {
            if (!ensureStarted()) return null;
            try {
                toServer.write(op + "\t" + b64(arg));
                toServer.newLine();
                toServer.flush();
                String response = readLineWithTimeout(CALL_TIMEOUT_MS);
                if (response == null) throw new IOException("timeout");
                if ("NIL".equals(response)) return null;
                if (response.startsWith("OK\t")) {
                    failures = 0;
                    return unb64(response.substring(3));
                }
                if (response.startsWith("ERR\t")) throw new IOException(unb64(response.substring(4)));
                throw new IOException("bad response: " + response);
            } catch (Throwable t) {
                failures++;
                System.err.println("[GuardCrypto] call " + op + " failed: " + t);
                stopLocked();
                if (failures >= MAX_FAILURES) {
                    cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS;
                    System.err.println("[GuardCrypto] disabled for " + (COOLDOWN_MS / 1000) + "s after "
                            + failures + " failures");
                }
                return null;
            }
        }
    }

    private static boolean ensureStarted() {
        if (System.currentTimeMillis() < cooldownUntil) return false;
        if (process != null && process.isAlive()) return true;
        File jar = shellJar;
        if (jar == null) return false;
        File libDir = new File(distDir(), "lib-unidbg");
        if (!libDir.isDirectory()) {
            System.err.println("[GuardCrypto] lib-unidbg missing: " + libDir.getAbsolutePath());
            cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS;
            return false;
        }
        try {
            File log = new File(jar.getParentFile(), "guardcrypto.log");
            ProcessBuilder builder = new ProcessBuilder(buildCommand(libDir, jar))
                    .redirectErrorStream(false)
                    .redirectError(ProcessBuilder.Redirect.to(log));
            process = builder.start();
            toServer = new BufferedWriter(new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8));
            fromServer = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8));
            long deadline = System.currentTimeMillis() + START_TIMEOUT_MS;
            String line;
            while ((line = readLineWithTimeout(Math.max(1, deadline - System.currentTimeMillis()))) != null) {
                if ("READY".equals(line.trim())) {
                    System.out.println("[GuardCrypto] service started for " + jar.getName());
                    failures = 0;
                    return true;
                }
            }
            throw new IOException("service did not become ready");
        } catch (Throwable t) {
            System.err.println("[GuardCrypto] start failed: " + t);
            stopLocked();
            failures++;
            if (failures >= MAX_FAILURES) cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS;
            return false;
        }
    }

    private static List<String> buildCommand(File libDir, File jar) {
        String javaBin = new File(new File(System.getProperty("java.home", "."), "bin"),
                isWindows() ? "java.exe" : "java").getAbsolutePath();
        String classpath = selfClasspath().getAbsolutePath()
                + File.pathSeparator + new File(libDir, "*").getAbsolutePath();
        List<String> command = new ArrayList<>();
        command.add(javaBin);
        command.add("-Xmx1g");
        command.add("-Dfile.encoding=UTF-8");
        command.add("-cp");
        command.add(classpath);
        command.add("com.fongmi.companion.guard.GuardCryptoService");
        command.add(jar.getAbsolutePath());
        command.add("--serve");
        return command;
    }

    /** 单次带超时的 readLine；超时返回 null，调用方负责杀进程。 */
    private static String readLineWithTimeout(long timeoutMs) throws Exception {
        final BufferedReader reader = fromServer;
        if (reader == null) return null;
        final String[] holder = new String[1];
        Thread thread = new Thread(() -> {
            try {
                holder[0] = reader.readLine();
            } catch (Throwable ignored) {
            }
        }, "guardcrypto-read");
        thread.setDaemon(true);
        thread.start();
        thread.join(Math.max(1, timeoutMs));
        if (thread.isAlive()) return null;
        return holder[0];
    }

    private static void stopLocked() {
        try {
            if (toServer != null) toServer.close();
        } catch (Throwable ignored) {
        }
        try {
            if (fromServer != null) fromServer.close();
        } catch (Throwable ignored) {
        }
        if (process != null) {
            try {
                process.destroy();
                if (!process.waitFor(2, TimeUnit.SECONDS)) process.destroyForcibly();
            } catch (Throwable ignored) {
                process.destroyForcibly();
            }
        }
        process = null;
        toServer = null;
        fromServer = null;
    }

    private static File selfClasspath() {
        try {
            URI location = GuardCryptoService.class.getProtectionDomain().getCodeSource().getLocation().toURI();
            return new File(location);
        } catch (Throwable t) {
            return new File(".").getAbsoluteFile();
        }
    }

    private static File distDir() {
        File self = selfClasspath();
        return self.isDirectory() ? self : self.getParentFile();
    }

    private static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");
    }

    // ==================================================================================
    // 协议工具
    // ==================================================================================

    private static String b64(String value) {
        return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private static String unb64(String value) {
        return new String(Base64.getDecoder().decode(value), StandardCharsets.UTF_8);
    }

    private static int[] parseInts(String csv) {
        if (csv == null || csv.trim().isEmpty()) return new int[0];
        String[] parts = csv.split(",");
        int[] result = new int[parts.length];
        for (int i = 0; i < parts.length; i++) result[i] = Integer.parseInt(parts[i].trim());
        return result;
    }

    static {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            synchronized (LOCK) {
                stopLocked();
            }
        }, "guardcrypto-shutdown"));
    }
}
