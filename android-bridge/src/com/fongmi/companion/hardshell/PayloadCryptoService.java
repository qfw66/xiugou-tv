package com.fongmi.companion.hardshell;

import com.fongmi.companion.ipc.LineProcess;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/**
 * 加固载荷的「native 代调服务」客户端：载荷 Java 类里的 native 方法（如 aowu 的
 * {@code MyCrypto.extDe/get/hxqSign}）转发到常驻子进程 {@link PayloadCryptoMain}，
 * 由 unidbg 执行载荷自带的 ARM64 库。
 *
 * <p>哪个载荷有 native、库在哪、需要什么环境变量，全部来自 {@link ShellProfile} 的
 * {@code crypto.*} 字段；本类不认识任何具体源。
 *
 * <p>这是<b>可选增强</b>：未登记载荷、缺 lib-unidbg、启动失败或熔断期间，{@link #call} 返回
 * {@code null}，调用方保留自己的兜底，不会把站点拖死。
 */
public final class PayloadCryptoService {

    /** 单次调用超时：native 调用实测毫秒级，留足余量。 */
    private static final long CALL_TIMEOUT_MS = 15_000;
    /** 冷启动超时：unidbg 启动 + {@code JNI_OnLoad} 实测约 3~5 s。 */
    private static final long START_TIMEOUT_MS = 60_000;
    private static final int MAX_FAILURES = 2;
    private static final long COOLDOWN_MS = 5 * 60_000L;

    /** 一次成功调用的结果；{@code value} 可为 null（native 本身返回 null）。 */
    public static final class Reply {
        public final Object value;

        Reply(Object value) {
            this.value = value;
        }

        public byte[] bytes() {
            return value instanceof byte[] ? (byte[]) value : null;
        }
    }

    private static final Object LOCK = new Object();
    private static File payloadJar;
    private static ShellProfile profile;
    private static LineProcess channel;
    private static int failures;
    private static long cooldownUntil;

    private PayloadCryptoService() {
    }

    /**
     * 登记当前载荷 jar；不是声明了 {@code crypto.so} 的载荷则忽略。换载荷时重启服务。
     *
     * @param jar 解壳得到的原始载荷（含 assets），不是 dex2jar 产物也可以——只要带着库条目
     */
    public static void remember(File jar) {
        if (jar == null || !jar.isFile()) return;
        ShellProfile matched = ShellRegistry.matchPayload(jar);
        if (matched == null || !matched.hasCrypto()) return;
        synchronized (LOCK) {
            if (payloadJar != null && payloadJar.getAbsolutePath().equals(jar.getAbsolutePath())) return;
            stopLocked();
            payloadJar = jar;
            profile = matched;
            failures = 0;
            cooldownUntil = 0;
            System.out.println("[PayloadCrypto] 已登记载荷 " + jar.getName() + "（" + matched.id + "）");
        }
    }

    /**
     * 停掉服务并忘掉已登记的载荷（换配置时调用）。下一次 {@link #remember} 会按需重新拉起。
     */
    public static void reset() {
        synchronized (LOCK) {
            stopLocked();
            payloadJar = null;
            profile = null;
            failures = 0;
            cooldownUntil = 0;
        }
    }

    /**
     * 代调载荷 native 静态方法。
     *
     * @param signature JNI 方法签名，如 {@code extDe(Ljava/lang/String;)[B}
     * @param args      仅支持 {@code null / Integer / String / byte[]}
     * @return 调用结果；服务不可用或调用失败时为 {@code null}
     */
    public static Reply call(String signature, Object... args) {
        String request;
        try {
            request = encodeRequest(signature, args);
        } catch (IllegalArgumentException e) {
            System.err.println("[PayloadCrypto] " + e.getMessage());
            return null;
        }
        synchronized (LOCK) {
            if (!ensureStarted()) return null;
            try {
                channel.send(request);
                String response = readFrame(System.currentTimeMillis() + CALL_TIMEOUT_MS);
                if (response == null) throw new IOException("timeout");
                Reply reply = decodeResponse(response);
                failures = 0;
                return reply;
            } catch (NativeError e) {
                // native 自身抛错不代表服务坏了：不计失败、不重启
                System.err.println("[PayloadCrypto] " + signature + " native 异常: " + e.getMessage());
                return null;
            } catch (Throwable t) {
                failures++;
                System.err.println("[PayloadCrypto] " + signature + " 调用失败: " + t);
                stopLocked();
                if (failures >= MAX_FAILURES) {
                    cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS;
                    System.err.println("[PayloadCrypto] 连续失败 " + failures + " 次，熔断 "
                            + (COOLDOWN_MS / 1000) + "s");
                }
                return null;
            }
        }
    }

    // ------------------------------------------------------------------ 协议

    static String encodeRequest(String signature, Object... args) {
        StringBuilder sb = new StringBuilder("CALL\t").append(signature);
        for (Object arg : args) {
            sb.append('\t');
            if (arg == null) {
                sb.append('N');
            } else if (arg instanceof Integer) {
                sb.append('I').append(arg);
            } else if (arg instanceof String) {
                sb.append('S').append(Base64.getEncoder()
                        .encodeToString(((String) arg).getBytes(StandardCharsets.UTF_8)));
            } else if (arg instanceof byte[]) {
                sb.append('B').append(Base64.getEncoder().encodeToString((byte[]) arg));
            } else {
                throw new IllegalArgumentException("不支持的参数类型: " + arg.getClass().getName());
            }
        }
        return sb.toString();
    }

    static Reply decodeResponse(String response) throws IOException {
        if ("NIL".equals(response)) return new Reply(null);
        if (response.startsWith("OK\t") && response.length() > 3) {
            char kind = response.charAt(3);
            byte[] raw = Base64.getDecoder().decode(response.substring(4));
            if (kind == 'B') return new Reply(raw);
            if (kind == 'S') return new Reply(new String(raw, StandardCharsets.UTF_8));
        }
        if (response.startsWith("ERR\t")) {
            throw new NativeError(new String(Base64.getDecoder().decode(response.substring(4)),
                    StandardCharsets.UTF_8));
        }
        throw new IOException("bad response: " + response);
    }

    /** 子进程报告的 native 异常（服务本身正常）。 */
    static final class NativeError extends IOException {
        NativeError(String message) {
            super(message);
        }
    }

    // ------------------------------------------------------------------ 子进程

    private static boolean ensureStarted() {
        if (channel != null && channel.isAlive()) return true;
        stopLocked(); // 进程已退出：先回收残留通道再决定是否重启
        if (payloadJar == null || System.currentTimeMillis() < cooldownUntil) return false;
        File libDir = new File(NativeProvisioner.distDir(), "lib-unidbg");
        File self = NativeProvisioner.selfClasspath();
        if (!libDir.isDirectory() || self == null) {
            System.err.println("[PayloadCrypto] 缺 lib-unidbg 或无法定位 classpath: " + libDir.getAbsolutePath());
            cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS;
            return false;
        }
        try {
            File cacheDir = payloadJar.getParentFile();
            List<String> command = new ArrayList<>();
            command.add(NativeProvisioner.javaBinary());
            command.add("-Xmx1g");
            command.add("-Dfile.encoding=UTF-8");
            command.add("-cp");
            command.add(self.getAbsolutePath() + File.pathSeparator + new File(libDir, "*").getAbsolutePath());
            // 必须是字符串：引用 PayloadCryptoMain.class 会在父 JVM 触发加载，而父进程没有 unidbg。
            command.add("com.fongmi.companion.hardshell.PayloadCryptoMain");
            command.add(payloadJar.getAbsolutePath());
            command.add(profile.id);
            File profiles = ShellRegistry.profilesDir(cacheDir);
            if (profiles != null) command.add(profiles.getAbsolutePath());

            File log = new File(cacheDir, "hardshell-" + profile.id + "-crypto.log");
            channel = LineProcess.start(new ProcessBuilder(command)
                    .redirectError(ProcessBuilder.Redirect.to(log)), "payloadcrypto");
            if ("READY".equals(readFrame(System.currentTimeMillis() + START_TIMEOUT_MS))) {
                System.out.println("[PayloadCrypto] 服务已启动: " + payloadJar.getName());
                return true;
            }
            throw new IOException("服务未就绪，日志见 " + log.getName());
        } catch (Throwable t) {
            System.err.println("[PayloadCrypto] 启动失败: " + t);
            stopLocked();
            failures++;
            if (failures >= MAX_FAILURES) cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS;
            return false;
        }
    }

    /** 必须与 {@code PayloadCryptoMain.FRAME} 一致（不能引用该类，见 ensureStarted 注释）。 */
    static final String FRAME = "PC";

    /**
     * 读到下一个协议帧并返回帧标记之后的内容；guest native 写到 stdout 的杂讯行或行首前缀一律丢弃。
     * 截止时间前没读到帧返回 null。
     */
    static String readFrame(long deadline) throws InterruptedException {
        String line;
        while ((line = readLineWithTimeout(Math.max(1, deadline - System.currentTimeMillis()))) != null) {
            int at = line.lastIndexOf(FRAME);
            if (at >= 0) return line.substring(at + FRAME.length());
            if (System.currentTimeMillis() >= deadline) return null;
        }
        return null;
    }

    private static String readLineWithTimeout(long timeoutMs) throws InterruptedException {
        LineProcess current = channel;
        return current == null ? null : current.readLine(timeoutMs);
    }

    /** 先杀进程再收通道（顺序见 {@link LineProcess} 类注释），不会因子进程挂起而卡住。 */
    private static void stopLocked() {
        if (channel != null) channel.close();
        channel = null;
    }

    static {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            synchronized (LOCK) {
                stopLocked();
            }
        }, "payloadcrypto-shutdown"));
    }
}
