package android.view;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * android.view.ViewTreeObserver 的桌面实现：桌面端没有布局遍历，监听器只保存不回调。
 */
public final class ViewTreeObserver {

    private final CopyOnWriteArrayList<OnGlobalLayoutListener> globalLayoutListeners = new CopyOnWriteArrayList<>();

    private final CopyOnWriteArrayList<OnGlobalFocusChangeListener> globalFocusListeners = new CopyOnWriteArrayList<>();
    private final CopyOnWriteArrayList<OnScrollChangedListener> scrollListeners = new CopyOnWriteArrayList<>();

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

    public void addOnGlobalFocusChangeListener(OnGlobalFocusChangeListener listener) {
        if (listener != null) globalFocusListeners.add(listener);
    }

    public void removeOnGlobalFocusChangeListener(OnGlobalFocusChangeListener listener) {
        globalFocusListeners.remove(listener);
    }

    public void addOnScrollChangedListener(OnScrollChangedListener listener) {
        if (listener != null) scrollListeners.add(listener);
    }

    public void removeOnScrollChangedListener(OnScrollChangedListener listener) {
        scrollListeners.remove(listener);
    }

    public boolean isAlive() {
        return true;
    }

    public interface OnGlobalLayoutListener {
        void onGlobalLayout();
    }

    public interface OnGlobalFocusChangeListener {
        void onGlobalFocusChanged(View oldFocus, View newFocus);
    }

    public interface OnScrollChangedListener {
        void onScrollChanged();
    }

    public interface OnPreDrawListener {
        boolean onPreDraw();
    }
}
