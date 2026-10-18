package android.os;

public class Bundle {

    private final java.util.HashMap<String, Object> map = new java.util.HashMap<>();

    public void putString(String key, String value) {
        map.put(key, value);
    }

    public String getString(String key) {
        Object v = map.get(key);
        return v instanceof String ? (String) v : null;
    }

    public void putInt(String key, int value) {
        map.put(key, value);
    }

    public int getInt(String key, int defValue) {
        Object v = map.get(key);
        return v instanceof Integer ? (Integer) v : defValue;
    }

    public boolean containsKey(String key) {
        return map.containsKey(key);
    }

    public java.util.Set<String> keySet() {
        return map.keySet();
    }
}
