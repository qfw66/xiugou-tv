package android.text;

/**
 * 带样式区段的文本。桌面端不保存样式区段，查询一律返回空结果。
 */
public interface Spanned extends CharSequence {

    int SPAN_EXCLUSIVE_EXCLUSIVE = 0x21;
    int SPAN_INCLUSIVE_INCLUSIVE = 0x12;
    int SPAN_INCLUSIVE_EXCLUSIVE = 0x11;
    int SPAN_EXCLUSIVE_INCLUSIVE = 0x22;

    @SuppressWarnings("unchecked")
    default <T> T[] getSpans(int start, int end, Class<T> type) {
        return (T[]) java.lang.reflect.Array.newInstance(type == null ? Object.class : type, 0);
    }

    default int getSpanStart(Object tag) {
        return -1;
    }

    default int getSpanEnd(Object tag) {
        return -1;
    }

    default int getSpanFlags(Object tag) {
        return 0;
    }

    default int nextSpanTransition(int start, int limit, Class<?> type) {
        return limit;
    }
}
