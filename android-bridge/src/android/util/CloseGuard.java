package android.util;

/**
 * android.util.CloseGuard：Android 用来提示「资源未关闭」的调试工具；桌面端不做检测。
 */
public final class CloseGuard {

    public void open(String closeMethodName) {
    }

    public void close() {
    }

    public void warnIfOpen() {
    }
}
