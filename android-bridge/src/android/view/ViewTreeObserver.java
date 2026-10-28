package android.view;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * android.view.ViewTreeObserver 的桌面实现：桌面端没有布局遍历，监听器只保存不回调。
 */
public final class ViewTreeObserver {

    private final CopyOnWriteArrayList<OnGlobalLayoutListener> globalLayoutListeners = new CopyOnWriteArrayList<>();

    public void addOnGlobalLayoutListener(OnGlobalLayoutListener listener) {
        if (listener != null) globalLayoutListeners.add(listener);
    }

    public void removeOnGlobalLayoutListener(OnGlobalLayoutListener listener) {
        globalLayoutListeners.remove(listener);
    }

    public void removeGlobalOnLayoutListener(OnGlobalLayoutListener listener) {
        removeOnGlobalLayoutListener(listener);
    }

    public void addOnPreDrawListener(OnPreDrawListener listener) {
    }

    public void removeOnPreDrawListener(OnPreDrawListener listener) {
    }

    public boolean isAlive() {
        return true;
    }

    public interface OnGlobalLayoutListener {
        void onGlobalLayout();
    }

    public interface OnPreDrawListener {
        boolean onPreDraw();
    }
}
