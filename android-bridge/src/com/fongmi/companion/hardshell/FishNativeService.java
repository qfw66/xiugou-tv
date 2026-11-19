package com.fongmi.companion.hardshell;

import com.fongmi.companion.ipc.LineProcess;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.IdentityHashMap;
import java.util.zip.ZipFile;
import org.json.JSONTokener;
import org.json.JSONObject;
import org.json.JSONArray;

/** Fish 载荷的原生调用边界；真实原生库在隔离子进程中执行，状态归属创建它的 loader。 */
public final class FishNativeService {
    static final String LIBRARY = "assets/FishGuard-v8.so";
    static final String LIBRARY_SHA256 = "c5eb72e0cd59c1e61c40bee6ba8b323b57784b9b533dc4861bef00f86d9cbd20";
    static final String FRAME = "\u0001FC\u0002";
    private static final int MAX_TEXT = 1024 * 1024;
    private static final Map<ClassLoader, Session> SESSIONS = new IdentityHashMap<>();

    private FishNativeService() {}

    public static void remember(ClassLoader loader, File payload) throws IOException {
        if (loader == null || payload == null || !payload.isFile()) return;
        try (ZipFile zip = new ZipFile(payload)) {
            if (zip.getEntry(LIBRARY) == null || zip.getEntry("assets/FishGuard.md5") == null) return;
        }
        String identity = sha256(payload);
        try { verifiedLibrary(payload, identity); }
        catch (IOException unsupported) {
            System.err.println("[FishNative] 保留载荷原生实现: " + unsupported.getMessage());
            return;
        }
        Session next = new Session(payload.getAbsoluteFile(), identity);
        Session previous;
        synchronized (SESSIONS) { previous = SESSIONS.put(loader, next); }
        if (previous != null) previous.close();
    }

    public static void load(String path) {
        try {
            File library = path == null ? null : new File(path);
            if (library == null || !library.isFile() || !LIBRARY_SHA256.equals(sha256(library))) {
                throw new IOException("Fish 请求的原生库尚未适配");
            }
            nativeCall("svN()I");
        } catch (IOException failure) { throw new IllegalStateException(failure.getMessage(), failure); }
    }

    public static boolean supports(ClassLoader loader) {
        synchronized (SESSIONS) { return SESSIONS.containsKey(loader); }
    }

    public static String decrypt(ClassLoader loader, String ext) throws IOException {
        if (!encrypted(ext)) return ext;
        Session session;
        synchronized (SESSIONS) { session = SESSIONS.get(loader); }
        return session == null ? ext : session.decrypt(ext.trim());
    }

    /** 调用者的载荷 loader 决定会话，禁止用最后加载的源作为全局默认。 */
    public static Object nativeCall(String signature, Object... args) {
        Session session = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE).walk(frames ->
                frames.map(frame -> frame.getDeclaringClass().getClassLoader()).map(loader -> {
                    synchronized (SESSIONS) { return SESSIONS.get(loader); }
                }).filter(java.util.Objects::nonNull).findFirst().orElse(null));
        if (session == null) throw new IllegalStateException("Fish 原生调用没有绑定载荷");
        try { return session.call(signature, args); }
        catch (IOException failure) { throw new IllegalStateException(failure.getMessage(), failure); }
    }

    public static void release(ClassLoader loader) {
        Session session;
        synchronized (SESSIONS) { session = SESSIONS.remove(loader); }
        if (session != null) session.close();
    }

    private static boolean encrypted(String value) {
        if (value == null) return false;
        String text = value.trim();
        if (text.length() < 24 || text.length() > MAX_TEXT || text.charAt(0) != 'A') return false;
        try {
            byte[] bytes = Base64.getDecoder().decode(text);
            return bytes.length >= 17 && bytes[0] == 1;
        } catch (IllegalArgumentException invalid) { return false; }
    }

    static byte[] verifiedLibrary(File payload, String identity) throws IOException {
        if (!identity.equals(sha256(payload))) throw new IOException("Fish 载荷在加载后发生变化");
        try (ZipFile zip = new ZipFile(payload)) {
            var entry = zip.getEntry(LIBRARY);
            var manifest = zip.getEntry("assets/FishGuard.md5");
            if (entry == null || manifest == null) throw new IOException("Fish 原生资源不完整");
            byte[] bytes;
            try (InputStream input = zip.getInputStream(entry)) { bytes = input.readNBytes(2 * MAX_TEXT + 1); }
            if (bytes.length > 2 * MAX_TEXT || !LIBRARY_SHA256.equals(hash(bytes, "SHA-256"))) {
                throw new IOException("Fish 原生库版本尚未验证，无法解密配置");
            }
            java.util.Properties properties = new java.util.Properties();
            try (InputStream input = zip.getInputStream(manifest)) { properties.load(input); }
            if (!hash(bytes, "MD5").equalsIgnoreCase(properties.getProperty("arm64-v8a", ""))) {
                throw new IOException("Fish 原生库清单校验失败");
            }
            return bytes;
        }
    }

    static String sha256(File file) throws IOException {
        try (InputStream input = java.nio.file.Files.newInputStream(file.toPath())) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
            return hex(digest.digest());
        } catch (java.security.NoSuchAlgorithmException impossible) { throw new IOException(impossible); }
    }

    private static String hash(byte[] bytes, String algorithm) throws IOException {
        try { return hex(MessageDigest.getInstance(algorithm).digest(bytes)); }
        catch (java.security.NoSuchAlgorithmException impossible) { throw new IOException(impossible); }
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte item : bytes) result.append(String.format("%02x", item & 255));
        return result.toString();
    }

    static String decodeExt(byte[] bytes) throws IOException {
        if (bytes.length == 0 || bytes.length > MAX_TEXT) throw new IOException("Fish 配置解密结果为空或过长");
        final String value;
        try {
            value = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().trim();
        } catch (java.nio.charset.CharacterCodingException invalid) { throw new IOException("Fish 配置不是有效 UTF-8"); }
        if (value.startsWith("{") || value.startsWith("[")) {
            try {
                JSONTokener json = new JSONTokener(value);
                Object parsed = json.nextValue();
                if ((parsed instanceof JSONObject || parsed instanceof JSONArray) && json.nextClean() == 0) return value;
            } catch (org.json.JSONException invalid) { /* 统一使用不含配置内容的错误。 */ }
        } else {
            try {
                URI uri = URI.create(value);
                if (("https".equals(uri.getScheme()) || "http".equals(uri.getScheme())) && uri.getHost() != null) return value;
            } catch (IllegalArgumentException invalid) { /* 统一使用不含配置内容的错误。 */ }
        }
        throw new IOException("Fish 配置解密结果不是有效 JSON 或 HTTP 地址");
    }

    private static final class Session {
        final File payload;
        final String identity;
        final String instance = java.util.UUID.randomUUID().toString();
        final Map<String, String> cache = new LinkedHashMap<>();
        volatile LineProcess channel;
        volatile boolean closed;
        volatile boolean failed;
        boolean ready;

        Session(File payload, String identity) { this.payload = payload; this.identity = identity; }

        synchronized String decrypt(String ext) throws IOException {
            checkAvailable();
            String cached = cache.get(ext);
            if (cached != null) return cached;
            Object decoded = call("extDe(Ljava/lang/String;)[B", ext);
            if (!(decoded instanceof byte[])) throw new IOException("Fish 原生库无法解密此配置");
            String value = decodeExt((byte[]) decoded);
            if (cache.size() >= 128) cache.remove(cache.keySet().iterator().next());
            cache.put(ext, value);
            return value;
        }

        synchronized Object call(String signature, Object... args) throws IOException {
            checkAvailable();
            boolean sent = false;
            try {
                start();
                LineProcess active = channel;
                if (closed || active == null) throw new IOException("Fish 原生服务已取消");
                StringBuilder request = new StringBuilder(signature);
                for (Object arg : args) {
                    request.append('\t');
                    if (arg == null) request.append('N');
                    else if (arg instanceof String) request.append('S').append(b64(((String) arg).getBytes(StandardCharsets.UTF_8)));
                    else if (arg instanceof byte[]) request.append('B').append(b64((byte[]) arg));
                    else if (arg instanceof Integer) request.append('I').append(arg);
                    else if (arg instanceof Long) request.append('J').append(arg);
                    else if (arg instanceof Boolean) request.append('Z').append(arg);
                    else if (arg instanceof android.content.Context) request.append('C');
                    else throw new IOException("Fish 原生参数类型不支持");
                }
                if (request.length() > 2 * MAX_TEXT) throw new IOException("Fish 原生参数过长");
                checkAvailable();
                sent = true;
                active.send(request.toString());
                String reply = readFrame(active, 15_000);
                if (reply == null) throw new IOException("Fish 原生调用超时或服务退出");
                if ("ERR".equals(reply)) throw new NativeFailure("Fish 原生方法执行失败: " + signature);
                if (!reply.startsWith("OK\t") || reply.length() < 4) throw new IOException("Fish 原生响应无效");
                if (closed) throw new IOException("Fish 原生服务已取消");
                String value = reply.substring(4);
                switch (reply.charAt(3)) {
                    case 'V': case 'N': return null;
                    case 'I': return Integer.parseInt(value);
                    case 'J': return Long.parseLong(value);
                    case 'Z': return Boolean.parseBoolean(value);
                    case 'B': return Base64.getDecoder().decode(value);
                    case 'S': return new String(Base64.getDecoder().decode(value), StandardCharsets.UTF_8);
                    case 'A':
                        if (value.isEmpty()) return new String[0];
                        String[] parts = value.split(",", -1);
                        for (int i = 0; i < parts.length; i++) parts[i] = parts[i].equals("~") ? null :
                                new String(Base64.getDecoder().decode(parts[i]), StandardCharsets.UTF_8);
                        return parts;
                    default: throw new IOException("Fish 原生响应类型不支持");
                }
            } catch (NativeFailure failure) {
                throw failure;
            } catch (InterruptedException cancelled) {
                if (sent || ready) failed = true;
                stop();
                Thread.currentThread().interrupt();
                throw new IOException("Fish 原生调用被中断");
            } catch (IllegalArgumentException invalid) {
                if (ready) failed = true;
                stop();
                throw new IOException("Fish 原生响应编码无效");
            } catch (IOException failure) {
                if (failure instanceof PreInterrupted) throw failure;
                if (ready) failed = true;
                stop();
                throw failure;
            }
        }

        private void checkAvailable() throws IOException {
            if (closed) throw new IOException("Fish 原生服务已取消");
            if (ready && (channel == null || !channel.isAlive())) { failed = true; stop(); }
            if (failed) throw new IOException("Fish 原生服务已失效，请重新加载配置");
            if (Thread.currentThread().isInterrupted()) throw new PreInterrupted();
        }

        private static String b64(byte[] value) { return Base64.getEncoder().encodeToString(value); }

        private void start() throws IOException, InterruptedException {
            if (channel != null && channel.isAlive()) return;
            if (ready) {
                failed = true;
                throw new IOException("Fish 原生服务已失效，请重新加载配置");
            }
            stop();
            verifiedLibrary(payload, identity);
            File dist = NativeProvisioner.distDir();
            File self = NativeProvisioner.selfClasspath();
            File libs = new File(dist, "lib-unidbg");
            if (self == null || !libs.isDirectory()) throw new IOException("Fish 配置解密缺少随包原生运行依赖");
            List<String> command = new ArrayList<>();
            command.add(NativeProvisioner.javaBinary());
            command.add("-Xverify:all");
            command.add("-Xmx512m");
            command.add("-Dfile.encoding=UTF-8");
            command.add("-Duser.home=" + System.getProperty("user.home", "."));
            command.add("-Djava.io.tmpdir=" + System.getProperty("java.io.tmpdir", "."));
            command.add("-cp");
            command.add(self.getAbsolutePath() + File.pathSeparator + new File(libs, "*").getAbsolutePath());
            command.add("com.fongmi.companion.hardshell.FishNativeMain");
            command.add(payload.getAbsolutePath());
            command.add(identity);
            File state = new File(new File(System.getProperty("java.io.tmpdir", "."), "fish-native"), instance);
            java.nio.file.Files.createDirectories(state.toPath());
            command.add(state.getAbsolutePath());
            File log = new File(new File(System.getProperty("user.home", "."), ".xiugou_tv_companion"),
                    "fish-native-" + identity.substring(0, 16) + "-" + instance + ".log");
            java.nio.file.Files.createDirectories(log.getParentFile().toPath());
            ProcessBuilder builder = new ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.to(log));
            builder.environment().keySet().removeAll(List.of("JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH"));
            LineProcess started = LineProcess.start(builder, "fish-native");
            channel = started;
            if (closed) { stop(); throw new IOException("Fish 配置解密已取消"); }
            if (!"READY".equals(readFrame(started, 60_000))) throw new IOException("Fish 原生解密服务启动失败");
            ready = true;
            System.out.println("[FishNative] 原生调用就绪 " + identity.substring(0, 16));
        }

        private void stop() {
            LineProcess old = channel;
            channel = null;
            if (old != null) old.close();
        }

        void close() { closed = true; stop(); }
    }

    private static final class NativeFailure extends IOException {
        NativeFailure(String message) { super(message); }
    }

    private static final class PreInterrupted extends IOException {
        PreInterrupted() { super("Fish 原生调用被中断"); }
    }

    private static String readFrame(LineProcess channel, long timeout) throws InterruptedException {
        long deadline = System.nanoTime() + timeout * 1_000_000L;
        while (true) {
            long remaining = (deadline - System.nanoTime()) / 1_000_000L;
            if (remaining <= 0) return null;
            String line = channel.readLine(remaining);
            if (line == null) return null;
            int marker = line.lastIndexOf(FRAME);
            if (marker >= 0) return line.substring(marker + FRAME.length());
        }
    }

    static {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            List<Session> old;
            synchronized (SESSIONS) { old = new ArrayList<>(SESSIONS.values()); SESSIONS.clear(); }
            for (Session session : old) session.close();
        }, "fish-native-shutdown"));
    }
}
