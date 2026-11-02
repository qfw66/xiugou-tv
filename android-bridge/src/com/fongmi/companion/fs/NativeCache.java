package com.fongmi.companion.fs;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * 原生库（.dll/.so）的落地缓存：按内容哈希放到固定目录（{@code native/<哈希>/<原文件名>}），
 * 相同内容跨进程、跨启动复用。
 *
 * <p>为什么不用 {@code createTempFile + deleteOnExit}：已加载的 DLL 在 Windows 上被进程锁住删不掉，
 * 子进程又常被 {@code destroyForcibly}（不跑退出钩子），旧做法每启动一次 unidbg 就在 %TEMP% 留下
 * 一份 6 MB 的 unicorn DLL 和一份 3.5 MB 的 .so（实测累计 155 个 / 900 MB）。
 */
public final class NativeCache {

    /** 一小时：仍在运行的解包子进程（超时上限 120 s）的工作目录不会被误删。 */
    private static final long STALE_WORKDIR_MS = 60 * 60_000L;
    private static final AtomicBoolean SWEPT = new AtomicBoolean();

    private NativeCache() {
    }

    /** 缓存根目录：{@code <用户目录>/.xiugou_tv_companion/native}（父子进程同一用户，天然共享）。 */
    public static File root() {
        return new File(new File(System.getProperty("user.home", "."), ".xiugou_tv_companion"), "native");
    }

    /**
     * 把一份原生库内容落地为缓存文件，内容相同则直接复用已有文件。
     *
     * @param fileName 原始文件名（如 {@code unicorn_java.dll}），落地后保持不变
     * @param in       库内容；本方法负责关闭
     */
    public static File materialize(String fileName, InputStream in) throws IOException {
        byte[] bytes;
        try (in) {
            bytes = in.readAllBytes();
        }
        // 按内容哈希分子目录、文件名保持原样：unidbg 以文件名作模块名，库本身也可能检查自身路径
        File dir = new File(root(), sha256Prefix(bytes));
        if (!dir.isDirectory() && !dir.mkdirs() && !dir.isDirectory()) {
            throw new IOException("无法创建原生库缓存目录: " + dir);
        }
        File target = new File(dir, fileName);
        if (target.isFile() && target.length() == bytes.length) return target;

        // 先写同目录临时文件再原子改名：并发启动的多个子进程不会读到半个文件
        File tmp = File.createTempFile("native-", ".part", dir);
        try {
            Files.write(tmp.toPath(), bytes);
            try {
                Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException e) {
            // 目标已被另一进程写好并加载（Windows 下被锁不能覆盖）：内容相同，直接用它
            if (target.isFile() && target.length() == bytes.length) return target;
            throw e;
        } finally {
            Files.deleteIfExists(tmp.toPath());
        }
        return target;
    }

    /**
     * 清扫旧版本留在 %TEMP% 的残留（每个进程只做一次，尽力而为，失败静默）。
     *
     * <ul>
     *   <li>{@code unicorn_java_*.dll}：旧 NativeLoader 的随机名产物；仍被进程加载的删不掉，自动跳过。</li>
     *   <li>{@code payloadcrypto-*}、{@code guardcrypto-*}：旧密码服务的解库目录，已不再创建。</li>
     *   <li>{@code hardshell-unwrap-*}：解包工作目录，正常在 finally 删除；只清一小时前的（被强杀遗留）。</li>
     * </ul>
     */
    public static void sweepLegacyTemp() {
        if (!SWEPT.compareAndSet(false, true)) return;
        File tmp = new File(System.getProperty("java.io.tmpdir", "."));
        File[] entries = tmp.listFiles();
        if (entries == null) return;
        long now = System.currentTimeMillis();
        int removed = 0;
        for (File f : entries) {
            String n = f.getName();
            boolean legacyDll = f.isFile() && n.startsWith("unicorn_java_") && n.endsWith(".dll");
            boolean legacyDir = f.isDirectory() && (n.startsWith("payloadcrypto-") || n.startsWith("guardcrypto-"));
            boolean staleWork = f.isDirectory() && n.startsWith("hardshell-unwrap-")
                    && now - f.lastModified() > STALE_WORKDIR_MS;
            if ((legacyDll || legacyDir || staleWork) && deleteTree(f)) removed++;
        }
        if (removed > 0) System.err.println("[NativeCache] 已清理 %TEMP% 旧残留 " + removed + " 项");
    }

    private static boolean deleteTree(File f) {
        File[] kids = f.listFiles();
        if (kids != null) {
            for (File k : kids) deleteTree(k);
        }
        return f.delete();
    }

    private static String sha256Prefix(byte[] bytes) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 8; i++) sb.append(String.format("%02x", d[i] & 0xff));
            return sb.toString();
        } catch (Exception e) {
            throw new IllegalStateException("SHA-256 不可用", e);
        }
    }
}
