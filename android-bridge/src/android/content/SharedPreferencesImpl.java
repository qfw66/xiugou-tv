package android.content;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/**
 * SharedPreferences 的桌面实现：内存 Map + JSON 行格式文件持久化，
 * 存放于 ~/.xiugou_tv_companion/prefs/&lt;name&gt;.json，跨进程重启保留。
 */
class SharedPreferencesImpl implements SharedPreferences {

    // Android 的 SharedPreferencesImpl 底层是允许 null key 的 Map（ArrayMap/HashMap），
    // 部分爬虫会用 getString(null, def) 探测默认项；ConcurrentHashMap 会对 null key 抛 NPE。
    private final Map<String, Object> map = java.util.Collections.synchronizedMap(new HashMap<>());
    private final File file;
    private final Object ioLock = new Object();

    SharedPreferencesImpl(String name, File dir) {
        String safeName = (name == null || name.trim().isEmpty()) ? "default" : name.trim().replaceAll("[^A-Za-z0-9_\\-]", "_");
        this.file = new File(dir, safeName + ".json");
        load();
    }

    private void load() {
        if (!file.exists()) return;
        int skipped = 0;
        boolean loadedLegacy = false;
        try {
            byte[] bytes = Files.readAllBytes(file.toPath());
            String text = new String(bytes, StandardCharsets.UTF_8);
            for (String line : text.split("\n")) {
                if (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
                if (line.isEmpty()) continue;
                try {
                    if (line.startsWith("v2\t")) {
                        loadV2Line(line);
                    } else {
                        loadLegacyLine(line);
                        loadedLegacy = true;
                    }
                } catch (Throwable ignored) {
                    skipped++;
                }
            }
            // 旧版已经写到磁盘但因解析错位而从未能恢复；读回后立即迁移为无歧义格式。
            if (loadedLegacy && !map.isEmpty()) save();
        } catch (Throwable error) {
            System.err.println("[SharedPreferences] load failed: " + file.getName()
                    + " (" + error.getClass().getSimpleName() + ")");
            return;
        }
        if (skipped > 0) {
            System.err.println("[SharedPreferences] skipped " + skipped
                    + " invalid record(s): " + file.getName());
        }
    }

    private void loadV2Line(String line) {
        String[] parts = line.split("\\t", -1);
        if (parts.length != 5 || !"v2".equals(parts[0]) || parts[1].length() != 1) {
            throw new IllegalArgumentException("invalid v2 record");
        }
        char tag = parts[1].charAt(0);
        String key = "n".equals(parts[2]) ? null : decodeUrl(parts[3]);
        if (!"n".equals(parts[2]) && !"s".equals(parts[2])) {
            throw new IllegalArgumentException("invalid key kind");
        }
        putDecoded(tag, key, decodeUrl(parts[4]));
    }

    /**
     * v1 格式为 {@code tag<TAB>base64(key)=base64(value)}。标准 Base64 自带 '=' 补位，
     * 因此不能用 indexOf/lastIndexOf；逐个候选分隔点验证两侧的规范 Base64，唯一命中才接受。
     */
    private void loadLegacyLine(String line) {
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
        putDecoded(tag, decodedKey, decodedValue);
    }

    private void putDecoded(char tag, String key, String value) {
        switch (tag) {
            case 's': map.put(key, value); break;
            case 'i': map.put(key, Integer.parseInt(value)); break;
            case 'l': map.put(key, Long.parseLong(value)); break;
            case 'f': map.put(key, Float.parseFloat(value)); break;
            case 'b':
                if (!"true".equals(value) && !"false".equals(value)) {
                    throw new IllegalArgumentException("invalid boolean");
                }
                map.put(key, Boolean.parseBoolean(value));
                break;
            default: throw new IllegalArgumentException("unknown type");
        }
    }

    private boolean save() {
        synchronized (ioLock) {
            File pending = null;
            try {
                File dir = file.getParentFile();
                if (dir != null && !dir.exists() && !dir.mkdirs() && !dir.isDirectory()) {
                    throw new java.io.IOException("cannot create prefs directory");
                }
                pending = File.createTempFile(file.getName() + ".", ".tmp", dir);
                StringBuilder sb = new StringBuilder();
                synchronized (map) {
                    for (Map.Entry<String, Object> e : map.entrySet()) {
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
                }
                Files.write(pending.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
                Files.move(pending.toPath(), file.toPath(),
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                return true;
            } catch (Throwable error) {
                if (pending != null) {
                    try { Files.deleteIfExists(pending.toPath()); } catch (Throwable ignored) {}
                }
                System.err.println("[SharedPreferences] save failed: " + file.getName()
                        + " (" + error.getClass().getSimpleName() + ")");
                return false;
            }
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
        return new HashMap<>(map);
    }

    @Override
    public String getString(String key, String defValue) {
        Object v = map.get(key);
        return v instanceof String ? (String) v : defValue;
    }

    @Override
    public Set<String> getStringSet(String key, Set<String> defValues) {
        Object v = map.get(key);
        if (v instanceof Set) {
            @SuppressWarnings("unchecked")
            Set<String> set = (Set<String>) v;
            return set;
        }
        return defValues;
    }

    @Override
    public int getInt(String key, int defValue) {
        Object v = map.get(key);
        return v instanceof Integer ? (Integer) v : defValue;
    }

    @Override
    public long getLong(String key, long defValue) {
        Object v = map.get(key);
        return v instanceof Long ? (Long) v : defValue;
    }

    @Override
    public float getFloat(String key, float defValue) {
        Object v = map.get(key);
        return v instanceof Float ? (Float) v : defValue;
    }

    @Override
    public boolean getBoolean(String key, boolean defValue) {
        Object v = map.get(key);
        return v instanceof Boolean ? (Boolean) v : defValue;
    }

    @Override
    public boolean contains(String key) {
        return map.containsKey(key);
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
            if (cleared) map.clear();
            for (String key : removals) map.remove(key);
            for (Map.Entry<String, Object> e : buffer.entrySet()) {
                if (e.getValue() == null) map.remove(e.getKey());
                else map.put(e.getKey(), e.getValue());
            }
            return save();
        }

        @Override
        public void apply() {
            commit();
        }
    }
}
