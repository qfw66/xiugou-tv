package android.window;

/**
 * 带预测性返回动画的回调（Android 14+）。
 */
public interface OnBackAnimationCallback extends OnBackInvokedCallback {

    default void onBackStarted(BackEvent backEvent) {
    }

    default void onBackProgressed(BackEvent backEvent) {
    }

    default void onBackCancelled() {
    }
}
