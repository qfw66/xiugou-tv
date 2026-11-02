package android.view;

import android.content.Context;
import android.os.Handler;

/**
 * 双指缩放识别器。桌面端不产生多点触摸，永远不处于缩放中、缩放系数恒为 1。
 */
public class ScaleGestureDetector {

    private final OnScaleGestureListener listener;
    private boolean quickScaleEnabled = true;
    private boolean stylusScaleEnabled;

    public ScaleGestureDetector(Context context, OnScaleGestureListener listener) {
        this(context, listener, null);
    }

    public ScaleGestureDetector(Context context, OnScaleGestureListener listener, Handler handler) {
        this.listener = listener;
    }

    public boolean onTouchEvent(MotionEvent event) {
        return false;
    }

    public boolean isInProgress() {
        return false;
    }

    public float getScaleFactor() {
        return 1f;
    }

    public float getFocusX() {
        return 0f;
    }

    public float getFocusY() {
        return 0f;
    }

    public float getCurrentSpan() {
        return 0f;
    }

    public float getPreviousSpan() {
        return 0f;
    }

    public long getTimeDelta() {
        return 0L;
    }

    public long getEventTime() {
        return 0L;
    }

    public void setQuickScaleEnabled(boolean scales) {
        this.quickScaleEnabled = scales;
    }

    public boolean isQuickScaleEnabled() {
        return quickScaleEnabled;
    }

    public void setStylusScaleEnabled(boolean scales) {
        this.stylusScaleEnabled = scales;
    }

    public boolean isStylusScaleEnabled() {
        return stylusScaleEnabled;
    }

    public interface OnScaleGestureListener {
        boolean onScale(ScaleGestureDetector detector);

        boolean onScaleBegin(ScaleGestureDetector detector);

        void onScaleEnd(ScaleGestureDetector detector);
    }

    /** 空实现；onScaleBegin 与 AOSP 一样默认返回 true。 */
    public static class SimpleOnScaleGestureListener implements OnScaleGestureListener {

        @Override
        public boolean onScale(ScaleGestureDetector detector) {
            return false;
        }

        @Override
        public boolean onScaleBegin(ScaleGestureDetector detector) {
            return true;
        }

        @Override
        public void onScaleEnd(ScaleGestureDetector detector) {
        }
    }
}
