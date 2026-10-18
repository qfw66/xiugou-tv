package android.content;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

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

    @SuppressWarnings("unchecked")
    private void load() {
        try {
            if (!file.exists()) return;
            byte[] bytes = Files.readAllBytes(file.toPath());
            String text = new String(bytes, StandardCharsets.UTF_8);
            for (String line : text.split("\n")) {
                if (line.isEmpty()) continue;
                // 每行格式：<type-tag>\t<base64(json key)>=<base64(json value)>
                int tab = line.indexOf('\t');
                int eq = line.indexOf('=', tab + 1);
                if (tab < 0 || eq < 0) continue;
                char tag = line.charAt(tab + 1);
                String key = decode(line.substring(tab + 2, eq));
                String value = decode(line.substring(eq + 1));
                switch (tag) {
                    case 's':
                        map.put(key, value);
                        break;
                    case 'i':
                        map.put(key, Integer.parseInt(value));
                        break;
                    case 'l':
                        map.put(key, Long.parseLong(value));
                        break;
                    case 'f':
                        map.put(key, Float.parseFloat(value));
                        break;
                    case 'b':
                        map.put(key, Boolean.parseBoolean(value));
                        break;
                    default:
                        break;
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private void save() {
        try {
            synchronized (ioLock) {
                File dir = file.getParentFile();
                if (dir != null && !dir.exists()) dir.mkdirs();
                StringBuilder sb = new StringBuilder();
                synchronized (map) {
                    for (Map.Entry<String, Object> e : map.entrySet()) {
                        Object v = e.getValue();
                        char tag;
                        if (v instanceof String) tag = 's';
                        else if (v instanceof Integer) tag = 'i';
                        else if (v instanceof Long) tag = 'l';
                        else if (v instanceof Float) tag = 'f';
                        else if (v instanceof Boolean) tag = 'b';
                        else continue;
                        sb.append(tag).append('\t').append(encode(e.getKey())).append('=').append(encode(String.valueOf(v))).append('\n');
                    }
                }
                Files.write(file.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Throwable ignored) {
        }
    }

    private static String encode(String s) {
        return java.util.Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    private static String decode(String s) {
        try {
            return new String(java.util.Base64.getDecoder().decode(s), StandardCharsets.UTF_8);
        } catch (Throwable t) {
            return "";
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
            save();
            return true;
        }

        @Override
        public void apply() {
            commit();
        }
    }
}
