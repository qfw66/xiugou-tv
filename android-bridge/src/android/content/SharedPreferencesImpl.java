package android.content;

import java.io.File;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AccessDeniedException;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;

/**
 * SharedPreferences 的桌面实现：内存 Map + JSON 行格式文件持久化，
 * 存放于 ~/.xiugou_tv_companion/prefs/&lt;name&gt;.json，跨进程重启保留。
 */
class SharedPreferencesImpl implements SharedPreferences {

    private static final long REFRESH_NANOS = TimeUnit.MILLISECONDS.toNanos(250);
    private static final long LOCK_TIMEOUT_NANOS = TimeUnit.SECONDS.toNanos(5);
    // 固定大小的锁条带避免实例增多时永久积累锁；同 JVM 的 FileLock 重叠不会等待。
    private static final ReentrantLock[] JVM_LOCKS = new ReentrantLock[64];
    static {
        for (int i = 0; i < JVM_LOCKS.length; i++) JVM_LOCKS[i] = new ReentrantLock();
    }

    // 所有实例内状态由 ioLock 保护；HashMap 保留 Android 的 null key 行为。
    private final Map<String, Object> map = new HashMap<>();
    private final Map<String, Object> pendingChanges = new HashMap<>();
    // 现有格式不持久化 StringSet，但同一实例内仍须可用，不能被读取刷新清掉。
    private final Map<String, Object> memoryOnly = new HashMap<>();
    private final File file;
    private final ReentrantLock jvmLock;
    private final Object ioLock = new Object();
    private boolean pendingClear;
    private boolean loadFailureReported;
    private boolean saveFailureReported;
    private boolean invalidRecordsReported;
    private long nextRefreshNanos;

    SharedPreferencesImpl(String name, File dir) {
        String safeName = (name == null || name.trim().isEmpty()) ? "default" : name.trim().replaceAll("[^A-Za-z0-9_\\-]", "_");
        File target = new File(dir, safeName + ".json");
        try { target = target.getCanonicalFile(); }
        catch (IOException ignored) { target = target.getAbsoluteFile(); }
        this.file = target;
        int hash = file.getPath().toLowerCase(java.util.Locale.ROOT).hashCode();
        this.jvmLock = JVM_LOCKS[(hash & Integer.MAX_VALUE) % JVM_LOCKS.length];
        synchronized (ioLock) { refresh(); }
    }

    private void refresh() {
        long now = System.nanoTime();
        if (nextRefreshNanos != 0 && now - nextRefreshNanos < 0) return;
        nextRefreshNanos = now + REFRESH_NANOS;
        try {
            // 原子替换保证普通读取看到完整版本；定期重读也覆盖同大小/同时间戳替换。
            DiskState state = readDisk();
            updateMemory(state.values);
            if (state.legacy && !state.values.isEmpty()) {
                try (DiskLock ignored = lockDisk()) {
                    // 迁移也必须在锁内重读，不能写回锁外读到的旧快照。
                    state = readDisk();
                    updateMemory(state.values);
                    if (state.legacy && !state.values.isEmpty()) writeDisk(state.values);
                }
            }
            loadFailureReported = false;
        } catch (Exception error) {
            if (!loadFailureReported) reportFailure("load", error);
            loadFailureReported = true;
        }
    }

    private static final class DiskState {
        final Map<String, Object> values = new HashMap<>();
        boolean legacy;
    }

    private DiskState readDisk() throws IOException {
        DiskState state = new DiskState();
        byte[] bytes;
        try { bytes = Files.readAllBytes(file.toPath()); }
        catch (NoSuchFileException missing) { return state; }
        int skipped = 0;
        String text = new String(bytes, StandardCharsets.UTF_8);
        for (String line : text.split("\n")) {
            if (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
            if (line.isEmpty()) continue;
            try {
                if (line.startsWith("v2\t")) {
                    loadV2Line(state.values, line);
                } else {
                    loadLegacyLine(state.values, line);
                    state.legacy = true;
                }
            } catch (RuntimeException ignored) {
                skipped++;
            }
        }
        if (skipped > 0 && !invalidRecordsReported) {
            System.err.println("[SharedPreferences] skipped " + skipped
                    + " invalid record(s): " + file.getName());
            invalidRecordsReported = true;
        }
        return state;
    }

    private static void loadV2Line(Map<String, Object> values, String line) {
        String[] parts = line.split("\\t", -1);
        if (parts.length != 5 || !"v2".equals(parts[0]) || parts[1].length() != 1) {
            throw new IllegalArgumentException("invalid v2 record");
        }
        char tag = parts[1].charAt(0);
        String key = "n".equals(parts[2]) ? null : decodeUrl(parts[3]);
        if (!"n".equals(parts[2]) && !"s".equals(parts[2])) {
            throw new IllegalArgumentException("invalid key kind");
        }
        putDecoded(values, tag, key, decodeUrl(parts[4]));
    }

    /**
     * v1 格式为 {@code tag<TAB>base64(key)=base64(value)}。标准 Base64 自带 '=' 补位，
     * 因此不能用 indexOf/lastIndexOf；逐个候选分隔点验证两侧的规范 Base64，唯一命中才接受。
     */
    private static void loadLegacyLine(Map<String, Object> values, String line) {
        if (line.length() < 3 || line.charAt(1) != '\t') {
            throw new IllegalArgumentException("invalid legacy record");
        }
        char tag = line.charAt(0);
        String payload = line.substring(2);
        String decodedKey = null;
        String decodedValue = null;
        int matches = 0;
        for (int i = 0; i < payload.length(); i++) {
            if (payload.charAt(i) != '=') continue;
            String key = decodeStandardCanonical(payload.substring(0, i));
            String value = decodeStandardCanonical(payload.substring(i + 1));
            if (key == null || value == null) continue;
            decodedKey = key;
            decodedValue = value;
            matches++;
        }
        if (matches != 1) throw new IllegalArgumentException("ambiguous legacy record");
        putDecoded(values, tag, decodedKey, decodedValue);
    }

    private static void putDecoded(Map<String, Object> values, char tag, String key, String value) {
        switch (tag) {
            case 's': values.put(key, value); break;
            case 'i': values.put(key, Integer.parseInt(value)); break;
            case 'l': values.put(key, Long.parseLong(value)); break;
            case 'f': values.put(key, Float.parseFloat(value)); break;
            case 'b':
                if (!"true".equals(value) && !"false".equals(value)) {
                    throw new IllegalArgumentException("invalid boolean");
                }
                values.put(key, Boolean.parseBoolean(value));
                break;
            default: throw new IllegalArgumentException("unknown type");
        }
    }

    private DiskLock lockDisk() throws IOException {
        long deadline = System.nanoTime() + LOCK_TIMEOUT_NANOS;
        boolean acquired = false;
        FileChannel channel = null;
        try {
            if (!jvmLock.tryLock(LOCK_TIMEOUT_NANOS, TimeUnit.NANOSECONDS)) {
                throw new IOException("prefs lock timeout");
            }
            acquired = true;
            Files.createDirectories(file.getParentFile().toPath());
            // 锁文件不可随数据原子替换，也不可在释放时删除，否则会锁住不同 inode。
            channel = FileChannel.open(new File(file.getPath() + ".lock").toPath(),
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
            while (true) {
                FileLock lock = null;
                try { lock = channel.tryLock(); }
                catch (OverlappingFileLockException ignored) { /* 另一类加载器也可能持锁。 */ }
                if (lock != null) return new DiskLock(channel, lock, jvmLock);
                if (System.nanoTime() - deadline >= 0) throw new IOException("prefs lock timeout");
                Thread.sleep(10);
            }
        } catch (IOException | RuntimeException | InterruptedException error) {
            if (channel != null) try { channel.close(); } catch (IOException ignored) {}
            if (acquired) jvmLock.unlock();
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            throw new IOException("cannot lock prefs", error);
        }
    }

    private static final class DiskLock implements AutoCloseable {
        private final FileChannel channel;
        private final FileLock lock;
        private final ReentrantLock jvmLock;

        DiskLock(FileChannel channel, FileLock lock, ReentrantLock jvmLock) {
            this.channel = channel;
            this.lock = lock;
            this.jvmLock = jvmLock;
        }

        @Override
        public void close() throws IOException {
            try {
                try { lock.release(); }
                finally { channel.close(); }
            } finally { jvmLock.unlock(); }
        }
    }

    private void writeDisk(Map<String, Object> values) throws IOException {
        File pending = File.createTempFile(file.getName() + ".", ".tmp", file.getParentFile());
        try {
            StringBuilder sb = new StringBuilder();
            for (Map.Entry<String, Object> e : values.entrySet()) {
                Object value = e.getValue();
                char tag;
                if (value instanceof String) tag = 's';
                else if (value instanceof Integer) tag = 'i';
                else if (value instanceof Long) tag = 'l';
                else if (value instanceof Float) tag = 'f';
                else if (value instanceof Boolean) tag = 'b';
                else continue;
                sb.append("v2\t").append(tag).append('\t')
                        .append(e.getKey() == null ? 'n' : 's').append('\t')
                        .append(e.getKey() == null ? "" : encodeUrl(e.getKey())).append('\t')
                        .append(encodeUrl(String.valueOf(value))).append('\n');
            }
            Files.write(pending.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
            // Windows 读者可能短暂占用目标文件，保留写锁和临时文件以完成同一次原子替换。
            for (int attempt = 0; ; attempt++) {
                try {
                    Files.move(pending.toPath(), file.toPath(),
                            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                    break;
                } catch (AccessDeniedException busy) {
                    if (File.separatorChar != '\\' || attempt >= 4) throw busy;
                    try {
                        Thread.sleep(50L << attempt);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        throw new IOException("等待替换偏好文件时被中断", interrupted);
                    }
                }
            }
        } finally {
            Files.deleteIfExists(pending.toPath());
        }
    }

    private void applyPending(Map<String, Object> values) {
        if (pendingClear) values.clear();
        for (Map.Entry<String, Object> e : pendingChanges.entrySet()) {
            if (e.getValue() == null) values.remove(e.getKey());
            else values.put(e.getKey(), e.getValue());
        }
    }

    private void updateMemory(Map<String, Object> values) {
        map.clear();
        map.putAll(values);
        map.putAll(memoryOnly);
        applyPending(map);
    }

    private boolean commitChanges(EditorImpl editor) {
        synchronized (ioLock) {
            if (editor.cleared) {
                pendingClear = true;
                pendingChanges.clear();
            }
            for (String key : editor.removals) pendingChanges.put(key, null);
            pendingChanges.putAll(editor.buffer);
            // 写失败仍保留内存增量；后续刷新/重试只覆盖这些键，不回写陈旧的无关项。
            applyPending(map);
            nextRefreshNanos = System.nanoTime() + REFRESH_NANOS;
            try (DiskLock ignored = lockDisk()) {
                Map<String, Object> latest = readDisk().values;
                applyPending(latest);
                updateMemory(latest);
                writeDisk(latest);
            } catch (Exception error) {
                if (!saveFailureReported) reportFailure("save", error);
                saveFailureReported = true;
                return false;
            }
            pendingClear = false;
            pendingChanges.clear();
            memoryOnly.clear();
            for (Map.Entry<String, Object> e : map.entrySet()) {
                if (e.getValue() instanceof Set) memoryOnly.put(e.getKey(), e.getValue());
            }
            saveFailureReported = false;
            return true;
        }
    }

    private void reportFailure(String operation, Exception error) {
        System.err.println("[SharedPreferences] " + operation + " failed: " + file.getName()
                + " (" + error.getClass().getSimpleName() + ")");
    }

    private Object getValue(String key) {
        synchronized (ioLock) {
            refresh();
            return map.get(key);
        }
    }

    private static String encodeUrl(String value) {
        return Base64.getUrlEncoder().withoutPadding()
                .encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private static String decodeUrl(String value) {
        return new String(Base64.getUrlDecoder().decode(value), StandardCharsets.UTF_8);
    }

    private static String decodeStandardCanonical(String value) {
        try {
            byte[] decoded = Base64.getDecoder().decode(value);
            if (!Base64.getEncoder().encodeToString(decoded).equals(value)) return null;
            return new String(decoded, StandardCharsets.UTF_8);
        } catch (Throwable ignored) {
            return null;
        }
    }

    @Override
    public Map<String, ?> getAll() {
        synchronized (ioLock) {
            refresh();
            Map<String, Object> all = new HashMap<>(map);
            all.putAll(DESKTOP_FORCED_STRINGS); // 与 getString 一致，载荷用 getAll 读也拿到桌面固定值
            return all;
        }
    }

    /**
     * 桌面端固定的字符串项：读取时总是返回这里的值，不管文件里存了什么、载荷传了什么默认值。
     *
     * <p>{@code pan.thread_proxy_mode}：网盘载荷默认 {@code go}，要加载 Android 版 Go 多线程库
     * （ELF），Windows 上永远起不来，playerContent 只返回
     * 「Go 多线程启动失败: Go 多线程未在启动阶段初始化完成」和空地址，所有网盘线路都播不了。
     * {@code java} 模式走载荷自带的 Java 分块代理，桌面端可用。
     */
    static final Map<String, String> DESKTOP_FORCED_STRINGS =
            java.util.Collections.singletonMap("pan.thread_proxy_mode", "java");

    @Override
    public String getString(String key, String defValue) {
        String forced = key == null ? null : DESKTOP_FORCED_STRINGS.get(key);
        if (forced != null) return forced;
        Object v = getValue(key);
        return v instanceof String ? (String) v : defValue;
    }

    @Override
    public Set<String> getStringSet(String key, Set<String> defValues) {
        Object v = getValue(key);
        if (v instanceof Set) {
            @SuppressWarnings("unchecked")
            Set<String> set = (Set<String>) v;
            return set;
        }
        return defValues;
    }

    @Override
    public int getInt(String key, int defValue) {
        Object v = getValue(key);
        return v instanceof Integer ? (Integer) v : defValue;
    }

    @Override
    public long getLong(String key, long defValue) {
        Object v = getValue(key);
        return v instanceof Long ? (Long) v : defValue;
    }

    @Override
    public float getFloat(String key, float defValue) {
        Object v = getValue(key);
        return v instanceof Float ? (Float) v : defValue;
    }

    @Override
    public boolean getBoolean(String key, boolean defValue) {
        Object v = getValue(key);
        return v instanceof Boolean ? (Boolean) v : defValue;
    }

    @Override
    public boolean contains(String key) {
        synchronized (ioLock) {
            refresh();
            return map.containsKey(key) || (key != null && DESKTOP_FORCED_STRINGS.containsKey(key));
        }
    }

    @Override
    public Editor edit() {
        return new EditorImpl();
    }

    @Override
    public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) {
    }

    @Override
    public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) {
    }

    private class EditorImpl implements Editor {
        private final Map<String, Object> buffer = new HashMap<>();
        private final Set<String> removals = new java.util.HashSet<>();
        private boolean cleared = false;

        @Override
        public Editor putString(String key, String value) {
            buffer.put(key, value);
            return this;
        }

        @Override
        public Editor putStringSet(String key, Set<String> values) {
            buffer.put(key, values == null ? null : new java.util.HashSet<>(values));
            return this;
        }

        @Override
        public Editor putInt(String key, int value) {
            buffer.put(key, value);
            return this;
        }

        @Override
        public Editor putLong(String key, long value) {
            buffer.put(key, value);
            return this;
        }

        @Override
        public Editor putFloat(String key, float value) {
            buffer.put(key, value);
            return this;
        }

        @Override
        public Editor putBoolean(String key, boolean value) {
            buffer.put(key, value);
            return this;
        }

        @Override
        public Editor remove(String key) {
            removals.add(key);
            return this;
        }

        @Override
        public Editor clear() {
            cleared = true;
            return this;
        }

        @Override
        public boolean commit() {
            return commitChanges(this);
        }

        @Override
        public void apply() {
            commit();
        }
    }
}
