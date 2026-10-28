package android.view;

/**
 * android.view.ViewParent 的最小接口：载荷只用 {@code getParent()} 做类型判断与向上查找。
 */
public interface ViewParent {

    default ViewParent getParent() {
        return this instanceof View ? ((View) this).getParent() : null;
    }

    default void requestLayout() {
    }

    default void requestDisallowInterceptTouchEvent(boolean disallowIntercept) {
    }
}
