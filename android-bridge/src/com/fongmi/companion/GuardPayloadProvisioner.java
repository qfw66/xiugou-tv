package com.fongmi.companion;

import java.io.File;
import java.io.InputStream;
import java.net.URI;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 加固壳载荷的**自动**获取：缓存未命中时，就地启动解密子进程还原载荷。
 *
 * 背景：`csp_*Guard` 站点的真实爬虫放在壳 jar 的 `assets/ftyshinidie.guard` 里，
 * 只能由同目录的 `ftyguard_v7|v8.so` 还原；桌面 JVM 跑不了 ARM 原生库，
 * 于是用 unidbg 起一段 Android 运行时（见 {@code com.fongmi.companion.guard.GuardDecryptor}）。
 *
 * 为什么要 fork 子进程而不是进程内调用：
 * - unidbg 与 unicorn 原生库共 27 MB，且会向临时目录释放 .dll，不该进常驻服务的 classpath；
 * - 模拟器崩溃/超时不该拖垮 companion；
 * - 解密是**一次性**成本（实测载荷解密 3.4 s，dex→jar 转换 6 s），结果按壳 md5 落盘复用。
 *
 * 依赖目录：与 companion-service.jar 同级的 `lib-unidbg/`（build.ps1 负责准备）。
 * 缺失时只打日志并返回 null，行为退回"拿不到载荷 → SpiderNull"，不影响其他站点。
 */
public final class GuardPayloadProvisioner {

    /** 解密子进程的超时（实测 3~4 s，留足冷启动与慢盘余量）。 */
    private static final long TIMEOUT_SECONDS = 180;
    /** 壳里的载荷资源名：命中任一即说明这是加固壳，而非普通 spider jar。 */
    private static final String[] GUARD_ASSETS = {
            "assets/ftyshinidie.guard",   // ftyguard 壳（饭太硬等）
            "assets/wexshinidie.guard",   // wexguard 壳（王二小放牛娃等）
    };

    private static final Map<String, Object> LOCKS = new ConcurrentHashMap<>();
    private static volatile boolean libDirReported = false;

    private GuardPayloadProvisioner() {
    }

    /** 载荷缓存路径约定：`payload-<壳内容 md5>.jar`。 */
    public static File payloadFile(File cacheDir, String contentMd5) {
        return new File(cacheDir, "payload-" + contentMd5.toLowerCase(java.util.Locale.ROOT) + ".jar");
    }

    /** 只做一次 zip 目录探查，判断是不是加固壳。 */
    public static boolean isGuardShell(File jar) {
        if (jar == null || !jar.isFile()) return false;
        try (ZipFile zip = new ZipFile(jar)) {
            for (String asset : GUARD_ASSETS) {
                ZipEntry entry = zip.getEntry(asset);
                if (entry != null && entry.getSize() != 0) return true;
            }
            return false;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * 确保载荷可用。
     *
     * @return 可直接交给 ClassLoader 的载荷 jar；无法获取时返回 null
     */
    public static File ensure(File cacheDir, File shellJar, String contentMd5, String label) {
        if (contentMd5 == null || contentMd5.trim().isEmpty()) return null;
        String md5 = contentMd5.trim().toLowerCase(java.util.Locale.ROOT);

        // 壳 jar 一定要体检一次：wexguard 之类会把 ARM 的 .so 交给 System.load，
        // 这类载荷在本机注定只有部分站点可用，越早知道越好。
        try {
            com.fongmi.companion.selfcheck.PayloadInspector.reportOnce(shellJar);
        } catch (Throwable ignored) {
        }

        File target = payloadFile(cacheDir, md5);
        if (target.isFile() && target.length() > 0) return target;
        if (!isGuardShell(shellJar)) return null;

        Object lock = LOCKS.computeIfAbsent(md5, k -> new Object());
        synchronized (lock) {
            if (target.isFile() && target.length() > 0) return target;

            File distDir = resolveDistDir();
            File libDir = new File(distDir, "lib-unidbg");
            if (!libDir.isDirectory()) {
                ParseStage.fail(ParseStage.DECRYPT, "缺少 unidbg 依赖目录: " + libDir.getAbsolutePath());
                if (!libDirReported) {
                    libDirReported = true;
                    System.err.println("[GuardDecrypt] 缺少 unidbg 依赖目录: " + libDir.getAbsolutePath()
                            + "（加固站点将退回 SpiderNull；请用 companion/build.ps1 构建以生成该目录）");
                }
                return null;
            }

            File log = new File(cacheDir, "guarddecrypt-" + md5 + ".log");
            long started = System.currentTimeMillis();
            System.out.println("[GuardDecrypt] 开始自动解密载荷 " + label + " (壳 md5 " + md5 + ")");
            try {
                Process process = new ProcessBuilder(buildCommand(resolveSelfClasspath(), libDir, shellJar, target))
                        .redirectErrorStream(true)
                        .redirectOutput(ProcessBuilder.Redirect.to(log))
                        .start();
                boolean finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
                if (!finished) {
                    process.destroyForcibly();
                    ParseStage.fail(ParseStage.DECRYPT, "解密超时 " + TIMEOUT_SECONDS + "s");
                    System.err.println("[GuardDecrypt] 超时 " + TIMEOUT_SECONDS + "s，详见 " + log.getAbsolutePath());
                    return null;
                }
                int exit = process.exitValue();
                long cost = System.currentTimeMillis() - started;
                if (exit == 0 && target.isFile() && target.length() > 0) {
                    System.out.println("[GuardDecrypt] 解密成功 " + target.getName()
                            + " (" + target.length() + " bytes, " + cost + "ms)");
                    return target;
                }
                ParseStage.fail(ParseStage.DECRYPT, "解密失败 exit=" + exit + "，详见 " + log.getName());
                System.err.println("[GuardDecrypt] 解密失败 exit=" + exit + " (" + cost + "ms)，详见 " + log.getAbsolutePath());
                // 失败时清掉半成品，避免下次误判为已缓存
                if (target.isFile() && target.length() == 0) target.delete();
                return null;
            } catch (Throwable t) {
                ParseStage.fail(ParseStage.DECRYPT, "启动解密进程失败: " + t);
                System.err.println("[GuardDecrypt] 启动解密进程失败: " + t);
                return null;
            }
        }
    }

    private static java.util.List<String> buildCommand(File selfClasspath, File libDir, File shellJar, File target) {
        String javaBin = new File(new File(System.getProperty("java.home", "."), "bin"),
                isWindows() ? "java.exe" : "java").getAbsolutePath();
        // selfClasspath 必须指向 companion-service.jar 本身（或开发态的 classes 目录），
        // 指向 dist 目录是不够的：目录里放的是 jar，不会自动被当成 classpath 条目展开。
        String classpath = selfClasspath.getAbsolutePath() + File.pathSeparator
                + new File(libDir, "*").getAbsolutePath();
        return Arrays.asList(
                javaBin,
                "-Xmx2g",
                "-Dfile.encoding=UTF-8",
                "-cp", classpath,
                "com.fongmi.companion.guard.GuardDecryptor",
                shellJar.getAbsolutePath(),
                target.getAbsolutePath());
    }

    /** 运行期自身所在位置：打包态是 companion-service.jar，开发态是 classes 目录。 */
    private static File resolveSelfClasspath() {
        try {
            URI location = GuardPayloadProvisioner.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI();
            return new File(location);
        } catch (Throwable t) {
            return new File(".").getAbsoluteFile();
        }
    }

    /**
     * 定位运行期目录（companion-service.jar 所在目录 / 开发态 classes 根）。
     * lib-unidbg 与 jar 同级，便于打包分发。
     */
    private static File resolveDistDir() {
        File self = resolveSelfClasspath();
        return self.isDirectory() ? self : self.getParentFile();
    }

    private static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT).contains("win");
    }

    /** 供诊断用：把子进程日志尾部读成字符串。 */
    public static String tailLog(File cacheDir, String contentMd5, int maxBytes) {
        if (contentMd5 == null || contentMd5.isEmpty()) return "";
        File log = new File(cacheDir, "guarddecrypt-" + contentMd5.toLowerCase(java.util.Locale.ROOT) + ".log");
        if (!log.isFile()) return "";
        try (InputStream in = new java.io.FileInputStream(log)) {
            long skip = Math.max(0, log.length() - maxBytes);
            long skipped = 0;
            while (skipped < skip) {
                long n = in.skip(skip - skipped);
                if (n <= 0) break;
                skipped += n;
            }
            byte[] buf = new byte[maxBytes];
            int read = 0, n;
            while (read < buf.length && (n = in.read(buf, read, buf.length - read)) > 0) read += n;
            return new String(buf, 0, Math.max(read, 0), java.nio.charset.StandardCharsets.UTF_8);
        } catch (Throwable t) {
            return "";
        }
    }
}
