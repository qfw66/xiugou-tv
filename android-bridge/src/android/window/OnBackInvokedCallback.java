package android.window;

/**
 * 返回手势回调（Android 13+）。桌面端的「返回」由宿主关闭弹窗承担，回调只登记不触发。
 */
public interface OnBackInvokedCallback {
    void onBackInvoked();
}
