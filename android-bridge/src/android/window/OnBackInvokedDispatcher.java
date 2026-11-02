package android.window;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 返回手势分发器：保存载荷登记的回调及优先级。桌面端不产生返回手势，回调不会被触发；
 * 弹窗的关闭仍走 {@code Dialog.hostRequestCancel()}（按返回键语义询问 OnKeyListener）。
 */
public class OnBackInvokedDispatcher {

    public static final int PRIORITY_DEFAULT = 0;
    public static final int PRIORITY_OVERLAY = 1000000;
    public static final int PRIORITY_SYSTEM_NAVIGATION_OBSERVER = -2;

    private final Map<OnBackInvokedCallback, Integer> callbacks = new ConcurrentHashMap<>();

    public void registerOnBackInvokedCallback(int priority, OnBackInvokedCallback callback) {
        if (callback == null) throw new IllegalArgumentException("callback must not be null");
        callbacks.put(callback, priority);
    }

    public void unregisterOnBackInvokedCallback(OnBackInvokedCallback callback) {
        if (callback != null) callbacks.remove(callback);
    }

    /** 已登记的回调数（桌面扩展，便于诊断）。 */
    public int getRegisteredCount() {
        return callbacks.size();
    }
}
