package android.webkit;

/** android.webkit.ValueCallback 空实现（JS 求值回调）。 */
public interface ValueCallback<T> {
    void onReceiveValue(T value);
}
