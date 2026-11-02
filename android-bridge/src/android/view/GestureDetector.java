package android.view;

import android.content.Context;
import android.os.Handler;

/**
 * 手势识别器。桌面端不产生触摸事件（宿主用遥控器 / 鼠标点击直接驱动 performClick），
 * 因此 {@link #onTouchEvent} 不识别任何手势、返回 false；监听器与开关状态如实保存。
 */
public class GestureDetector {

    private final OnGestureListener listener;
    private OnDoubleTapListener doubleTapListener;
    private OnContextClickListener contextClickListener;
    private boolean longpressEnabled = true;

    public GestureDetector(Context context, OnGestureListener listener) {
        this(context, listener, null);
    }

    public GestureDetector(Context context, OnGestureListener listener, Handler handler) {
        if (listener == null) throw new NullPointerException("OnGestureListener must not be null");
        this.listener = listener;
        if (listener instanceof OnDoubleTapListener) doubleTapListener = (OnDoubleTapListener) listener;
        if (listener instanceof OnContextClickListener) contextClickListener = (OnContextClickListener) listener;
    }

    public GestureDetector(OnGestureListener listener) {
        this(null, listener, null);
    }

    public boolean onTouchEvent(MotionEvent ev) {
        return false;
    }

    public boolean onGenericMotionEvent(MotionEvent ev) {
        return false;
    }

    public void setOnDoubleTapListener(OnDoubleTapListener onDoubleTapListener) {
        this.doubleTapListener = onDoubleTapListener;
    }

    public void setContextClickListener(OnContextClickListener onContextClickListener) {
        this.contextClickListener = onContextClickListener;
    }

    public void setIsLongpressEnabled(boolean isLongpressEnabled) {
        this.longpressEnabled = isLongpressEnabled;
    }

    public boolean isLongpressEnabled() {
        return longpressEnabled;
    }

    public interface OnGestureListener {
        boolean onDown(MotionEvent e);

        void onShowPress(MotionEvent e);

        boolean onSingleTapUp(MotionEvent e);

        boolean onScroll(MotionEvent e1, MotionEvent e2, float distanceX, float distanceY);

        void onLongPress(MotionEvent e);

        boolean onFling(MotionEvent e1, MotionEvent e2, float velocityX, float velocityY);
    }

    public interface OnDoubleTapListener {
        boolean onSingleTapConfirmed(MotionEvent e);

        boolean onDoubleTap(MotionEvent e);

        boolean onDoubleTapEvent(MotionEvent e);
    }

    public interface OnContextClickListener {
        boolean onContextClick(MotionEvent e);
    }

    /** 全部回调的空实现，载荷按需覆写。 */
    public static class SimpleOnGestureListener implements OnGestureListener, OnDoubleTapListener,
            OnContextClickListener {

        @Override
        public boolean onSingleTapUp(MotionEvent e) {
            return false;
        }

        @Override
        public void onLongPress(MotionEvent e) {
        }

        @Override
        public boolean onScroll(MotionEvent e1, MotionEvent e2, float distanceX, float distanceY) {
            return false;
        }

        @Override
        public boolean onFling(MotionEvent e1, MotionEvent e2, float velocityX, float velocityY) {
            return false;
        }

        @Override
        public void onShowPress(MotionEvent e) {
        }

        @Override
        public boolean onDown(MotionEvent e) {
            return false;
        }

        @Override
        public boolean onDoubleTap(MotionEvent e) {
            return false;
        }

        @Override
        public boolean onDoubleTapEvent(MotionEvent e) {
            return false;
        }

        @Override
        public boolean onSingleTapConfirmed(MotionEvent e) {
            return false;
        }

        @Override
        public boolean onContextClick(MotionEvent e) {
            return false;
        }
    }
}
