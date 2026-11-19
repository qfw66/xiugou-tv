package com.fongmi.companion;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** One PHP process per call, matching drpy-node's init-before-call semantics. */
final class PhpRuntime implements AutoCloseable {
    private static final int MAX_INPUT = 4 * 1024 * 1024;
    private static final int MAX_OUTPUT = 32 * 1024 * 1024;
    private static final Semaphore SLOTS = new Semaphore(4, true);
    private static final ExecutorService IO = Executors.newCachedThreadPool(task -> {
        Thread thread = new Thread(task, "php-rpc-io"); thread.setDaemon(true); return thread;
    });
    private final Path script;
    private final Set<Process> children = new HashSet<>();
    private boolean closed;

    PhpRuntime(Path script) { this.script = script; }

    Object call(String method, Map<String, Object> env, Object... args) throws Exception {
        long timeout = Math.max(1, Math.min(90_000, Long.getLong("xiugou.php.timeoutMs", 40_000)));
        if (!SLOTS.tryAcquire(timeout, TimeUnit.MILLISECONDS)) throw new IOException("PHP 调用繁忙，请稍后重试");
        Process child = null;
        Future<byte[]> pending = null;
        try {
            byte[] input = JsonCodec.stringify(Map.of("file", script.toString(), "method", method,
                    "env", env, "args", Arrays.asList(args))).getBytes(StandardCharsets.UTF_8);
            if (input.length > MAX_INPUT) throw new IOException("PHP 调用参数超过 4 MiB");
            List<String> command = command(script.getParent().resolve(".xiugou-bridge.php"));
            ProcessBuilder builder = new ProcessBuilder(command).directory(script.getParent().toFile());
            builder.redirectError(ProcessBuilder.Redirect.DISCARD);
            builder.environment().remove("PHPRC");
            builder.environment().put("PHP_INI_SCAN_DIR", "");
            synchronized (this) {
                if (closed || Thread.currentThread().isInterrupted()) throw new IOException("PHP 源已释放");
                try { child = builder.start(); }
                catch (IOException error) { throw new IOException("PHP 8.3+ 运行时不可用，请检查 companion/dist/phpruntime"); }
                children.add(child);
            }
            Process owned = child;
            pending = IO.submit(() -> {
                try (OutputStream stdin = owned.getOutputStream()) { stdin.write(input); }
                try (InputStream stdout = owned.getInputStream()) {
                    byte[] bytes = stdout.readNBytes(MAX_OUTPUT + 1);
                    if (bytes.length > MAX_OUTPUT) throw new IOException("PHP 响应超过 32 MiB，请使用流式代理");
                    return bytes;
                }
            });
            long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeout);
            byte[] output = pending.get(timeout, TimeUnit.MILLISECONDS);
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0 || !child.waitFor(remaining, TimeUnit.NANOSECONDS)) throw new TimeoutException();
            Map<String, Object> result;
            try { result = JsonCodec.parseObject(new String(output, StandardCharsets.UTF_8)); }
            catch (RuntimeException error) { throw new IOException("PHP 返回了无效响应（退出码 " + child.exitValue() + "）"); }
            if (!Boolean.TRUE.equals(result.get("ok")) || child.exitValue() != 0) {
                String kind = String.valueOf(result.getOrDefault("kind", "进程退出码 " + child.exitValue()));
                String line = String.valueOf(result.getOrDefault("line", "?"));
                throw new IOException("PHP " + method + " 执行失败：" + kind + "，行 " + line);
            }
            synchronized (this) { if (closed) throw new IOException("PHP 源已释放"); }
            return result.get("value");
        } catch (TimeoutException error) {
            throw new IOException("PHP " + method + " 调用超时，子进程已终止");
        } catch (ExecutionException error) {
            throw new IOException("PHP " + method + " 响应读取失败或超过 32 MiB");
        } finally {
            if (child != null) {
                terminate(child);
                synchronized (this) { children.remove(child); }
            }
            if (pending != null) pending.cancel(true);
            SLOTS.release();
        }
    }

    static List<String> command(Path bridge) {
        String override = System.getProperty("xiugou.php", "").trim();
        File executable = override.isEmpty() ? bundledBinary() : new File(override);
        String binary = executable == null ? "php" : executable.getAbsolutePath();
        List<String> command = new ArrayList<>(List.of(binary));
        if (executable != null && new File(executable.getParentFile(), "ext/php_curl.dll").isFile()) {
            File runtime = executable.getParentFile();
            command.add("-n");
            option(command, "extension_dir=" + new File(runtime, "ext").getAbsolutePath());
            for (String extension : List.of("curl", "mbstring", "openssl", "sockets", "sqlite3", "pdo_sqlite", "pdo_mysql", "mysqli")) {
                option(command, "extension=" + extension);
            }
            File certificates = new File(runtime, "cacert.pem");
            if (certificates.isFile()) {
                option(command, "curl.cainfo=" + certificates.getAbsolutePath());
                option(command, "openssl.cafile=" + certificates.getAbsolutePath());
            }
        }
        option(command, "display_errors=0");
        option(command, "log_errors=0");
        option(command, "memory_limit=512M");
        command.add(bridge.toAbsolutePath().toString());
        return command;
    }

    private static void option(List<String> command, String value) { command.add("-d"); command.add(value); }

    private static File bundledBinary() {
        try {
            File self = new File(PhpRuntime.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            File directory = self.isDirectory() ? self : self.getParentFile();
            String name = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win") ? "php.exe" : "php";
            File bundled = new File(directory, "phpruntime/" + name);
            if (bundled.isFile()) return bundled;
            File development = new File("companion/phpruntime/" + name);
            if (development.isFile()) return development;
        } catch (Exception ignored) { }
        return null;
    }

    private static void terminate(Process child) {
        child.descendants().forEach(handle -> { try { handle.destroyForcibly(); } catch (RuntimeException ignored) { } });
        if (child.isAlive()) child.destroyForcibly();
        try { child.waitFor(2, TimeUnit.SECONDS); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); }
    }

    @Override public void close() {
        List<Process> owned;
        synchronized (this) { closed = true; owned = new ArrayList<>(children); }
        owned.forEach(PhpRuntime::terminate);
    }
}
