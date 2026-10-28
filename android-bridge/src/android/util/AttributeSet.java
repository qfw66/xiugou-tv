package android.util;

/**
 * Minimal android.util.AttributeSet stub（仅类型占位）。
 */
public interface AttributeSet {

    default String getAttributeValue(String namespace, String name) {
        return null;
    }

    default int getAttributeCount() {
        return 0;
    }
}
