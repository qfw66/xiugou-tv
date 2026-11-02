package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * py 源的子进程运行时：一个脚本一个 CPython 进程，行式 JSON-RPC 通信。
 *
 * <h3>为什么是子进程</h3>
 * 与 {@code NativeProvisioner} 拉起 unidbg 同构：解释器与 site-packages 体积不小，
 * 不进 fat jar，放 {@code dist/pyruntime} 同级；脚本会起本地 server、会死循环，
 * 进程隔离能把故障挡在 companion 之外。
 *
 * <h3>解释器与脚本目录的定位顺序</h3>
 * <pre>
 *   python：-Dxiugou.python=... → dist/pyruntime/{python.exe,python3,python} → PATH 上的 python
 *   pyshell：dist/pyshell → 开发回退到仓库内 companion/pyshell
 * </pre>
 *
 * <h3>与 JS 引擎的差别</h3>
 * JS 是进程内引擎（{@code JavaScriptSpider}），py 必须跨进程；所以这里的每次
 * {@link #callJson} 都是一次同步往返，超时或子进程死亡都会被直接观察到。
 */
public final class PyRuntime implements AutoCloseable {

    /** 单次方法调用超时：首调可能要下载/建连，留足余量。 */
    private static final long CALL_TIMEOUT_MS = 90_000L;

    /** 下载脚本的超时。 */
    private static final int SCRIPT_TIMEOUT_MS = 30_000;

    private static final String UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Edg/148.0.0.0";

    private final Process process;
    private final BufferedWriter stdin;
    private final BufferedReader stdout;
    private final ExecutorService reader = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "py-runtime-reader");
        t.setDaemon(true);
        return t;
    });
    private int nextId = 1;
    private boolean closed;
    /** load 阶段脚本自报的方法表，用于判断可选方法是否存在。 */
    private Map<String, Object> loadInfo;

    private PyRuntime(Process process) {
        this.process = process;
        this.stdin = new BufferedWriter(new OutputStreamWriter(
                process.getOutputStream(), StandardCharsets.UTF_8));
        this.stdout = new BufferedReader(new InputStreamReader(
                process.getInputStream(), StandardCharsets.UTF_8));
    }

    // ------------------------------------------------------------------ 启动

    /**
     * 拉起子进程并加载脚本。
     *
     * @param scriptFile 已落盘的 .py
     * @param ext        脚本 init 参数
     * @param logFile    子进程 stderr 落盘位置
     */
    public static PyRuntime start(File scriptFile, String ext, File logFile) throws Exception {
        File shell = shellDir();
        File runner = new File(shell, "runner.py");
        if (!runner.isFile()) {
            throw new IllegalStateException("找不到 pyshell/runner.py: " + runner.getAbsolutePath());
        }

        List<String> cmd = new ArrayList<>();
        cmd.add(pythonBinary());
        cmd.add("-X");
        cmd.add("utf8");
        cmd.add("-u");
        cmd.add(runner.getAbsolutePath());

        ProcessBuilder pb = new ProcessBuilder(cmd);
        File parent = logFile.getParentFile();
        if (parent != null) parent.mkdirs();
        pb.directory(shell);
        System.out.println("[PyRuntime] python=" + cmd.get(0)
                + "  pyshell=" + shell.getAbsolutePath());
        // stdout 是协议流，绝不能重定向；stderr 落盘便于排障
        pb.redirectErrorStream(false);
        pb.redirectError(ProcessBuilder.Redirect.appendTo(logFile));
        Map<String, String> env = pb.environment();
        env.put("PYTHONIOENCODING", "utf-8");
        env.put("PYTHONUTF8", "1");
        String proxy = System.getProperty("xiugou.proxy.base", "");
        if (!proxy.isEmpty()) env.put("XIUGOU_PROXY_BASE", proxy);

        PyRuntime rt = new PyRuntime(pb.start());
        try {
            Map<String, Object> ready = rt.readOne();
            if (!"ready".equals(ready.get("type"))) {
                throw new IllegalStateException("runner 未就绪: " + ready);
            }
            Map<String, Object> req = new LinkedHashMap<>();
            req.put("id", rt.nextId++);
            req.put("action", "load");
            req.put("api", scriptFile.getAbsolutePath());
            req.put("ext", ext == null ? "" : ext);
            Map<String, Object> resp = rt.request(req);
            if (!"result".equals(resp.get("type"))) {
                throw new IllegalStateException("脚本加载失败: " + resp.get("error"));
            }
            Object value = resp.get("value");
            rt.loadInfo = value instanceof Map ? castMap(value) : new LinkedHashMap<>();
            return rt;
        } catch (Throwable t) {
            rt.close();
            throw t instanceof Exception ? (Exception) t : new Exception(t);
        }
    }

    /** 解释器：显式指定 → 随包分发的便携运行时 → PATH。 */
    private static String pythonBinary() {
        String override = System.getProperty("xiugou.python");
        if (override != null && !override.trim().isEmpty()) return override.trim();

        File runtime = new File(distDir(), "pyruntime");
        String[] names = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")
                ? new String[]{"python.exe"}
                : new String[]{"bin/python3", "bin/python", "python3", "python"};
        for (String n : names) {
            File f = new File(runtime, n);
            if (f.isFile()) return f.getAbsolutePath();
        }
        return "python";
    }

    /** pyshell 目录：优先随包的 dist/pyshell，开发期回退到仓库内。 */
    static File shellDir() {
        File packaged = new File(distDir(), "pyshell");
        if (new File(packaged, "runner.py").isFile()) return packaged;
        File dev = new File("companion/pyshell");
        if (new File(dev, "runner.py").isFile()) return dev;
        return packaged;
    }

    private static File distDir() {
        File self = selfClasspath();
        if (self != null) return self.isDirectory() ? self : self.getParentFile();
        return new File(".").getAbsoluteFile();
    }

    private static File selfClasspath() {
        try {
            return new File(PyRuntime.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
        } catch (Throwable t) {
            return null;
        }
    }

    // ------------------------------------------------------------------ 调用

    /**
     * 调用脚本方法，返回 CatVod 契约要求的 **JSON 文本**。
     *
     * @return 序列化后的结果；脚本返回 None 时返回 null
     */
    public synchronized String callJson(String method, List<Object> args) throws Exception {
        if (closed) throw new IllegalStateException("py 运行时已关闭");
        Map<String, Object> req = new LinkedHashMap<>();
        req.put("id", nextId++);
        req.put("action", "call");
        req.put("method", method);
        req.put("args", args == null ? new ArrayList<>() : args);

        Map<String, Object> resp = request(req);
        if ("error".equals(resp.get("type"))) {
            String err = String.valueOf(resp.get("error"));
            String trace = String.valueOf(resp.get("trace"));
            throw new IllegalStateException(method + " 失败: " + err
                    + (trace.isEmpty() ? "" : "\n" + tail(trace, 600)));
        }
        Object value = resp.get("value");
        return value == null ? null : JsonCodec.stringify(value);
    }

    /**
     * 一次请求往返。任何「这条通道已不可用」的情况都必须 {@link #close()}：
     * 子进程已退出（读到 EOF → ExecutionException）、看门狗中断、写管道失败、超时。
     * 否则 closed 仍为 false，读线程与进程句柄残留，之后每次调用都往死管道里写。
     */
    private Map<String, Object> request(Map<String, Object> req) throws Exception {
        try {
            stdin.write(JsonCodec.stringify(req));
            stdin.write("\n");
            stdin.flush();
        } catch (java.io.IOException e) {
            close();
            throw new IllegalStateException("py 子进程已退出（写入失败）: " + e.getMessage(), e);
        }

        Future<Map<String, Object>> f = reader.submit(this::readOne);
        try {
            return f.get(CALL_TIMEOUT_MS, TimeUnit.MILLISECONDS);
        } catch (java.util.concurrent.TimeoutException te) {
            f.cancel(true);
            close();
            throw new IllegalStateException("py 调用超时（" + CALL_TIMEOUT_MS + "ms）");
        } catch (java.util.concurrent.ExecutionException ee) {
            close();
            Throwable cause = ee.getCause() == null ? ee : ee.getCause();
            throw cause instanceof Exception ? (Exception) cause : new IllegalStateException(cause);
        } catch (InterruptedException ie) {
            // 看门狗取消：回包已不可能对齐（下一次读会读到这次的响应），整条通道作废
            f.cancel(true);
            close();
            Thread.currentThread().interrupt();
            throw ie;
        }
    }

    /** 通道是否仍可用（未关闭且子进程存活）。 */
    public boolean isAlive() {
        return !closed && process.isAlive();
    }

    private Map<String, Object> readOne() throws Exception {
        while (true) {
            String line = stdout.readLine();
            if (line == null) throw new IllegalStateException("py 子进程已退出（stdout EOF）");
            Map<String, Object> resp = JsonCodec.parseObject(line);
            // runner 的心跳，用于让子进程感知父进程消失；与请求无关，直接跳过
            if ("ping".equals(resp.get("type"))) continue;
            return resp;
        }
    }

    private static String tail(String s, int n) {
        return s.length() <= n ? s : s.substring(s.length() - n);
    }

    /** 脚本是否声明了该方法（决定可选方法返回 null 还是真的去调用）。 */
    public boolean hasMethod(String method) {
        if (loadInfo == null) return false;
        Object methods = loadInfo.get("methods");
        if (!(methods instanceof List)) return true; // 拿不到方法表时不拦截，交给脚本自己报错
        for (Object m : (List<?>) methods) {
            if (method.equals(String.valueOf(m))) return true;
        }
        return false;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> castMap(Object o) {
        return (Map<String, Object>) o;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        try {
            process.destroyForcibly();
        } catch (Throwable ignored) {
        }
        reader.shutdownNow();
    }

    // ------------------------------------------------------------------ 脚本获取

    /**
     * 把 api 变成本地可执行脚本，必要时下载并缓存。
     *
     * <p><b>blob → raw 归一</b>：配置里的 api 普遍写的是 GitHub 的 blob 页面
     * （返回 HTML 而不是源码），必须换成 raw 才能执行。
     */
    public static File ensureScript(String api, File cacheDir) throws Exception {
        String url = encodeUrl(normalizeScriptUrl(api));
        if (url.isEmpty()) throw new IllegalArgumentException("空 api");
        File dir = new File(cacheDir, "py");
        dir.mkdirs();
        File target = new File(dir, md5(url) + ".py");
        if (target.isFile() && target.length() > 0) return target;

        // 本地路径直接可用（自检 / 离线投放）
        File local = new File(api);
        if (local.isFile()) return local;

        File tmp = new File(dir, target.getName() + ".pending");
        HttpURLConnection conn = (HttpURLConnection) URI.create(url).toURL().openConnection();
        conn.setRequestProperty("User-Agent", UA);
        conn.setConnectTimeout(15_000);
        conn.setReadTimeout(SCRIPT_TIMEOUT_MS);
        conn.setInstanceFollowRedirects(true);
        try (InputStream in = conn.getInputStream()) {
            Files.copy(in, tmp.toPath(), StandardCopyOption.REPLACE_EXISTING);
        } finally {
            conn.disconnect();
        }
        if (!tmp.isFile() || tmp.length() == 0) {
            throw new IllegalStateException("脚本下载为空: " + url);
        }
        Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
        System.out.println("[PySpider] 脚本就绪: " + target.getName() + " (" + target.length() + " B)");
        return target;
    }

    /**
     * GitHub blob 页面 → raw 内容地址。其它形式原样返回。
     *
     * <pre>
     * https://gh-proxy.com/https://github.com/o/r/blob/main/a/b.py
     *   → https://gh-proxy.com/https://raw.githubusercontent.com/o/r/main/a/b.py
     * </pre>
     * 代理前缀会被保留，避免破坏需要借道的环境。
     */
    public static String normalizeScriptUrl(String api) {
        if (api == null) return "";
        String a = api.trim();
        if (a.isEmpty()) return "";
        int idx = a.indexOf("github.com/");
        if (idx < 0 || a.indexOf("/blob/", idx) < 0) return a;

        String prefix = a.substring(0, idx);
        String rest = a.substring(idx + "github.com/".length());
        int blob = rest.indexOf("/blob/");
        String ownerRepo = rest.substring(0, blob);
        String after = rest.substring(blob + "/blob/".length());
        return prefix + "raw.githubusercontent.com/" + ownerRepo + "/" + after;
    }

    /**
     * 非 ASCII 字符转 %XX，ASCII 原样保留（含 {@code %}，因此已编码的 %XX 不会被二次编码）。
     *
     * <p>实测配置里 147 个 api 有超过一半写的是**未编码的原始中文文件名**
     * （{@code .../py/黄果漫剧.py}）。浏览器会自动编码，{@code java.net.URI} 不会——
     * 直接把裸中文塞进 URL 会被代理/服务端以 400 拒绝。
     */
    static String encodeUrl(String url) {
        if (url == null || url.isEmpty()) return "";
        boolean ascii = true;
        for (int i = 0; i < url.length(); i++) {
            if (url.charAt(i) > 0x7F) {
                ascii = false;
                break;
            }
        }
        if (ascii) return url;

        StringBuilder sb = new StringBuilder(url.length() + 32);
        for (byte b : url.getBytes(StandardCharsets.UTF_8)) {
            int c = b & 0xFF;
            if (c < 0x80) {
                sb.append((char) c);
            } else {
                sb.append('%').append(Character.toUpperCase(Character.forDigit(c >> 4, 16)))
                        .append(Character.toUpperCase(Character.forDigit(c & 0xF, 16)));
            }
        }
        return sb.toString();
    }

    static String md5(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] d = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Throwable t) {
            return Integer.toHexString(s.hashCode());
        }
    }
}
