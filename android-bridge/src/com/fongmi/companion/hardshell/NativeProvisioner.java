package com.fongmi.companion.hardshell;

import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 通用载荷预置：把「壳容器」变成「可 dex2jar 的普通载荷 jar」，并缓存复用。
 *
 * <p>全部行为由 {@link ShellProfile} 参数化，<b>本类不认识任何具体源</b>。
 *
 * <h3>容器来源（两种模式，由 profile 决定）</h3>
 * <ol>
 *   <li><b>索引模式</b>（{@code indexUrls}）：GET 索引 → 响应里含 {@code {md5,url}} → 下载并核对 md5。
 *       索引地址可留空，此时由 {@link ShellProfile#discoverIndexUrls} 从壳 dex 字面量自动还原。</li>
 *   <li><b>直链模式</b>（{@code containerUrls}）：索引地址就是容器本体。</li>
 * </ol>
 *
 * <h3>解包</h3>
 * 交给子进程 {@link UnwrapMain}（unidbg 只进编译期 classpath，不进主 jar），
 * 产物写 {@code cacheDir/<id>-<壳 md5>.jar}，下次直接命中缓存。
 *
 * <h3>失败语义</h3>
 * 任何一步失败都返回 {@code null}，上层继续走原有兜底路径，不把站点拖死。
 */
public final class NativeProvisioner {

    /**
     * 解包入口类名。
     *
     * <p><b>必须写成字符串</b>：用 {@code UnwrapMain.class} 会在**父 JVM**里触发类加载，
     * 而父 JVM 的 classpath 上没有 unidbg（只进编译期 / 子进程），会直接
     * NoClassDefFoundError。与 {@code GuardCryptoService} 的处理保持一致。
     */
    public static final String DEFAULT_UNWRAP_MAIN = "com.fongmi.companion.hardshell.UnwrapMain";

    /** 伪装 UA：源站对非浏览器 UA 会返回错误页。 */
    private static final String UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Edg/148.0.0.0";

    private static final Pattern MD5_FIELD = Pattern.compile("\"md5\"\\s*:\\s*\"([0-9a-fA-F]{32})\"");
    private static final Pattern URL_FIELD = Pattern.compile("\"url\"\\s*:\\s*\"([^\"]+)\"");

    private final ShellProfile profile;

    public NativeProvisioner(ShellProfile profile) {
        this.profile = profile;
    }

    private String tag() {
        return "[Hardshell/" + profile.id + "]";
    }

    private File payloadFile(File cacheDir, String key) {
        return new File(cacheDir, profile.cachePrefix() + "-" + key + ".jar");
    }

    private File containerFile(File cacheDir, String key) {
        return new File(cacheDir, profile.cachePrefix() + "-container-" + key + ".jar");
    }

    /** 已解包载荷的纯查缓存（不下载、不需要壳 jar）。 */
    public File cached(File cacheDir, String key) {
        String k = normalizedKey(key);
        if (k == null) return null;
        File target = payloadFile(cacheDir, k);
        if (target.isFile() && target.length() > 0 && profile.isPayload(target)) return target;
        return null;
    }

    /**
     * 若 {@code shellJar} 属于本 profile，返回解密后的载荷 jar；否则返回 {@code null}。
     *
     * @param cacheDir jars 缓存目录
     * @param shellJar 已下载的壳 jar
     * @param shellMd5 壳 jar 的 md5（缓存键）；为空则现算
     */
    public File ensure(File cacheDir, File shellJar, String shellMd5) {
        try {
            if (!profile.isShell(shellJar)) return null;
            // 形态登记但没配 native 解包链（只声明了特征）：不解包，交给下游。
            if (!profile.canUnwrap()) {
                System.out.println(tag() + " 该形态未配置解包链，保留原 jar");
                return null;
            }
            String key = normalizedKey(shellMd5);
            if (key == null) key = md5Of(shellJar);
            if (key.isEmpty()) return null;

            File target = payloadFile(cacheDir, key);
            if (target.isFile() && target.length() > 0 && profile.isPayload(target)) {
                System.out.println(tag() + " 命中本地载荷: " + target.getName());
                return target;
            }

            File container = containerFor(cacheDir, key, shellJar);
            if (container == null) {
                System.err.println(tag() + " 容器获取失败，保留壳交给下游");
                return null;
            }

            File produced = new File(cacheDir, profile.cachePrefix() + "-" + key + ".pending.jar");
            int code = runUnwrap(cacheDir, container, produced);
            if (code != 0 || !produced.isFile() || !profile.isPayload(produced)) {
                System.err.println(tag() + " 解包失败（exit=" + code + "）");
                //noinspection ResultOfMethodCallIgnored
                produced.delete();
                return null;
            }
            Files.move(produced.toPath(), target.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            System.out.println(tag() + " 载荷就绪: " + target.getName() + " (" + target.length() + " B)");
            return target;
        } catch (Throwable t) {
            System.err.println(tag() + " ensure 异常，保留壳交给下游: " + t);
            return null;
        }
    }

    /** 对齐 {@code DexSpiderLoader} 的既有调用形态。 */
    public File ensure(File cacheDir, File shellJar) {
        return ensure(cacheDir, shellJar, null);
    }

    // ------------------------------------------------------------------ 容器获取

    private File containerFor(File cacheDir, String key, File shellJar) {
        if (profile.containerUrls.length > 0) {
            // 直链模式：索引地址本身就是容器。
            return download(cacheDir, key, profile.containerUrls, null);
        }
        String[] indexes = resolveIndexUrls(shellJar);
        if (indexes.length == 0) {
            System.err.println(tag() + " 找不到可用索引地址（dex 里也没有可拼接的 URL）");
            return null;
        }
        String payloadUrl = null;
        String expectedMd5 = null;
        for (String index : indexes) {
            try {
                String json = httpGet(index, 20_000);
                Matcher mu = URL_FIELD.matcher(json);
                if (!mu.find()) {
                    System.err.println(tag() + " 索引无 url 字段: " + index);
                    continue;
                }
                payloadUrl = mu.group(1).trim();
                Matcher mm = MD5_FIELD.matcher(json);
                if (mm.find()) expectedMd5 = mm.group(1).trim().toLowerCase(Locale.ROOT);
                break;
            } catch (Throwable t) {
                System.err.println(tag() + " 索引不可用 " + index + " : " + t.getMessage());
            }
        }
        if (payloadUrl == null || payloadUrl.isEmpty()) return null;
        return download(cacheDir, key, new String[]{payloadUrl}, expectedMd5);
    }

    /** 索引地址：profile 显式给出优先，否则从壳自身还原。 */
    private String[] resolveIndexUrls(File shellJar) {
        List<String> urls = profile.discoverIndexUrls(shellJar, 8);
        if (!urls.isEmpty() && profile.indexUrls.length == 0) {
            System.out.println(tag() + " 自动发现索引候选: " + urls);
        }
        return urls.toArray(new String[0]);
    }

    private File download(File cacheDir, String key, String[] urls, String expectedMd5) {
        File cached = containerFile(cacheDir, key);
        if (cached.isFile() && cached.length() > 0) {
            System.out.println(tag() + " 命中本地容器: " + cached.getName());
            return cached;
        }
        for (String url : urls) {
            if (JarIndex.isEmpty(url)) continue;
            boolean matches = expectedMd5 == null || expectedMd5.isEmpty();
            try {
                File tmp = new File(cacheDir, profile.cachePrefix() + "-container-" + key + ".pending");
                httpGetToFile(url, tmp, 180_000);
                if (!tmp.isFile() || tmp.length() == 0) continue;
                if (!matches) {
                    String actual = md5Of(tmp);
                    if (!actual.equalsIgnoreCase(expectedMd5)) {
                        System.err.println(tag() + " 容器 md5 不符（期望 " + expectedMd5
                                + " 实际 " + actual + "），换下一个地址");
                        //noinspection ResultOfMethodCallIgnored
                        tmp.delete();
                        continue;
                    }
                }
                Files.move(tmp.toPath(), cached.toPath(),
                        java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                System.out.println(tag() + " 容器就绪: " + cached.getName()
                        + " (" + cached.length() + " B)");
                return cached;
            } catch (Throwable t) {
                System.err.println(tag() + " 容器下载失败 " + url + ": " + t);
            }
        }
        return null;
    }

    // ------------------------------------------------------------------ 子进程

    /** 以 {@code -cp "<自身 jar>;lib-unidbg/*"} 拉起 {@link UnwrapMain}，返回退出码。 */
    private int runUnwrap(File cacheDir, File container, File outJar) {
        File libDir = new File(distDir(), "lib-unidbg");
        if (!libDir.isDirectory()) {
            System.err.println(tag() + " 缺 lib-unidbg: " + libDir.getAbsolutePath());
            return -1;
        }
        File self = selfClasspath();
        if (self == null || !(self.isFile() || self.isDirectory())) {
            System.err.println(tag() + " 无法定位 companion classpath，跳过解包");
            return -1;
        }
        try {
            List<String> command = new ArrayList<>();
            command.add(javaBinary());
            command.add("-Xmx1g");
            command.add("-Dfile.encoding=UTF-8");
            command.add("-cp");
            command.add(self.getAbsolutePath() + File.pathSeparator
                    + new File(libDir, "*").getAbsolutePath());
            command.add(profile.unwrapMain);
            command.add(container.getAbsolutePath());
            command.add(outJar.getAbsolutePath());
            command.add(profile.id);
            File profiles = ShellRegistry.profilesDir(cacheDir);
            if (profiles != null) command.add(profiles.getAbsolutePath());

            ProcessBuilder builder = new ProcessBuilder(command);
            builder.redirectErrorStream(true);
            File log = new File(cacheDir, "hardshell-" + profile.id + "-unwrap.log");
            builder.redirectOutput(ProcessBuilder.Redirect.appendTo(log));

            Process process = builder.start();
            if (!process.waitFor(profile.unwrapTimeoutMs, TimeUnit.MILLISECONDS)) {
                process.destroyForcibly();
                System.err.println(tag() + " 解包超时，日志见 " + log.getName());
                return -1;
            }
            int code = process.exitValue();
            if (code != 0) {
                System.err.println(tag() + " 解包退出码 " + code + "，日志见 " + log.getName());
            }
            return code;
        } catch (Throwable t) {
            System.err.println(tag() + " 解包子进程失败: " + t);
            return -1;
        }
    }

    static String javaBinary() {
        String exe = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")
                ? "java.exe" : "java";
        return new File(new File(System.getProperty("java.home", "."), "bin"), exe).getAbsolutePath();
    }

    /** companion 的 dist 目录（unidbg 依赖同级放置）。 */
    static File distDir() {
        File self = selfClasspath();
        if (self != null) {
            // 生产：java -jar <dist>/companion-service.jar → 取 dist。
            // 开发/探针：classpath 指向 classes 目录 → 该目录即"dist"。
            return self.isDirectory() ? self : self.getParentFile();
        }
        return new File(".").getAbsoluteFile();
    }

    /** 当前运行的 companion jar（`java -jar` 形态）。 */
    static File selfClasspath() {
        try {
            return new File(NativeProvisioner.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
        } catch (Throwable t) {
            return null;
        }
    }

    // ------------------------------------------------------------------ 网络与工具

    private static String httpGet(String url, int timeoutMs) throws Exception {
        HttpURLConnection conn = open(url, timeoutMs);
        try (InputStream in = conn.getInputStream()) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } finally {
            conn.disconnect();
        }
    }

    private static void httpGetToFile(String url, File target, int timeoutMs) throws Exception {
        HttpURLConnection conn = open(url, timeoutMs);
        try (InputStream in = conn.getInputStream();
             OutputStream out = Files.newOutputStream(target.toPath())) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } finally {
            conn.disconnect();
        }
    }

    private static HttpURLConnection open(String url, int timeoutMs) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) URI.create(url).toURL().openConnection();
        conn.setRequestProperty("User-Agent", UA);
        conn.setConnectTimeout(Math.min(timeoutMs, 20_000));
        conn.setReadTimeout(timeoutMs);
        conn.setInstanceFollowRedirects(true);
        return conn;
    }

    private static String normalizedKey(String key) {
        if (JarIndex.isEmpty(key)) return null;
        return key.trim().toLowerCase(Locale.ROOT);
    }

    static String md5Of(File file) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            try (InputStream in = Files.newInputStream(file.toPath())) {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            }
            StringBuilder sb = new StringBuilder();
            for (byte b : md.digest()) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Throwable t) {
            return "";
        }
    }
}
