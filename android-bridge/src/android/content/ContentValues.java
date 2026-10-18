package android.content;

import java.util.HashMap;
import java.util.Map;

/**
 * Minimal android.content.ContentValues stub for standard JVM environment.
 */
public class ContentValues {

    private final Map<String, Object> values = new HashMap<>();

    public void put(String key, String value) {
        values.put(key, value);
    }

    public void put(String key, Byte value) {
        values.put(key, value);
    }

    public void put(String key, Short value) {
        values.put(key, value);
    }

    public void put(String key, Integer value) {
        values.put(key, value);
    }

    public void put(String key, Long value) {
        values.put(key, value);
    }

    public void put(String key, Float value) {
        values.put(key, value);
    }

    public void put(String key, Double value) {
        values.put(key, value);
    }

    public void put(String key, Boolean value) {
        values.put(key, value);
    }

    public void put(String key, byte[] value) {
        values.put(key, value);
    }

    public void putNull(String key) {
        values.put(key, null);
    }

    public Object get(String key) {
        return values.get(key);
    }

    public String getAsString(String key) {
        Object v = values.get(key);
        return v != null ? String.valueOf(v) : null;
    }

    public Integer getAsInteger(String key) {
        Object v = values.get(key);
        return v instanceof Integer ? (Integer) v : null;
    }

    public Long getAsLong(String key) {
        Object v = values.get(key);
        return v instanceof Number ? ((Number) v).longValue() : null;
    }

    public Boolean getAsBoolean(String key) {
        Object v = values.get(key);
        return v instanceof Boolean ? (Boolean) v : null;
    }

    public boolean containsKey(String key) {
        return values.containsKey(key);
    }

    public void remove(String key) {
        values.remove(key);
    }

    public void clear() {
        values.clear();
    }

    public int size() {
        return values.size();
    }
}
