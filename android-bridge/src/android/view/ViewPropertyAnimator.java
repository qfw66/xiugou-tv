package android.view;

import android.animation.Animator;
import android.animation.TimeInterpolator;

import java.util.ArrayList;
import java.util.List;

/**
 * android.view.ViewPropertyAnimator 的桌面实现。
 *
 * <p>Android 上 {@code view.animate().alpha(1f)...} 不必调用 start()，会在下一帧自动开始。
 * 这里在第一次登记属性时向 UI 线程投递一次「执行」，{@link #start()} 则立即执行；
 * 执行时属性一步写到终值，再依次回调 withStartAction、监听器与 withEndAction。
 */
public class ViewPropertyAnimator {

    private static final int ALPHA = 0;
    private static final int SCALE_X = 1;
    private static final int SCALE_Y = 2;
    private static final int TRANSLATION_X = 3;
    private static final int TRANSLATION_Y = 4;
    private static final int TRANSLATION_Z = 5;
    private static final int ROTATION = 6;
    private static final int ROTATION_X = 7;
    private static final int ROTATION_Y = 8;
    private static final int X = 9;
    private static final int Y = 10;

    private final View view;
    /** 待执行的属性：{类型, 值, 是否为增量}。 */
    private final List<float[]> pending = new ArrayList<>();
    private boolean scheduled;
    private long duration = 300;
    private long startDelay;
    private TimeInterpolator interpolator;
    private Animator.AnimatorListener listener;
    private Runnable startAction;
    private Runnable endAction;

    /** 回调监听时传给载荷的动画对象（Android 传的是内部 ValueAnimator，载荷可能读它的时长等）。 */
    private final Animator proxy = new Animator() {
        @Override
        public Animator setDuration(long d) {
            ViewPropertyAnimator.this.setDuration(d);
            return this;
        }

        @Override
        public long getDuration() {
            return duration;
        }

        @Override
        public void start() {
            ViewPropertyAnimator.this.start();
        }

        @Override
        public void cancel() {
            ViewPropertyAnimator.this.cancel();
        }
    };

    ViewPropertyAnimator(View view) {
        this.view = view;
    }

    public ViewPropertyAnimator alpha(float value) {
        return add(ALPHA, value, false);
    }

    public ViewPropertyAnimator alphaBy(float value) {
        return add(ALPHA, value, true);
    }

    public ViewPropertyAnimator scaleX(float value) {
        return add(SCALE_X, value, false);
    }

    public ViewPropertyAnimator scaleXBy(float value) {
        return add(SCALE_X, value, true);
    }

    public ViewPropertyAnimator scaleY(float value) {
        return add(SCALE_Y, value, false);
    }

    public ViewPropertyAnimator scaleYBy(float value) {
        return add(SCALE_Y, value, true);
    }

    public ViewPropertyAnimator translationX(float value) {
        return add(TRANSLATION_X, value, false);
    }

    public ViewPropertyAnimator translationXBy(float value) {
        return add(TRANSLATION_X, value, true);
    }

    public ViewPropertyAnimator translationY(float value) {
        return add(TRANSLATION_Y, value, false);
    }

    public ViewPropertyAnimator translationYBy(float value) {
        return add(TRANSLATION_Y, value, true);
    }

    public ViewPropertyAnimator translationZ(float value) {
        return add(TRANSLATION_Z, value, false);
    }

    public ViewPropertyAnimator rotation(float value) {
        return add(ROTATION, value, false);
    }

    public ViewPropertyAnimator rotationBy(float value) {
        return add(ROTATION, value, true);
    }

    public ViewPropertyAnimator rotationX(float value) {
        return add(ROTATION_X, value, false);
    }

    public ViewPropertyAnimator rotationY(float value) {
        return add(ROTATION_Y, value, false);
    }

    public ViewPropertyAnimator x(float value) {
        return add(X, value, false);
    }

    public ViewPropertyAnimator y(float value) {
        return add(Y, value, false);
    }

    public ViewPropertyAnimator setDuration(long duration) {
        if (duration < 0) throw new IllegalArgumentException("Animators cannot have negative duration: " + duration);
        this.duration = duration;
        return this;
    }

    public long getDuration() {
        return duration;
    }

    public ViewPropertyAnimator setStartDelay(long startDelay) {
        this.startDelay = startDelay;
        return this;
    }

    public long getStartDelay() {
        return startDelay;
    }

    public ViewPropertyAnimator setInterpolator(TimeInterpolator interpolator) {
        this.interpolator = interpolator;
        return this;
    }

    public TimeInterpolator getInterpolator() {
        return interpolator;
    }

    public ViewPropertyAnimator setListener(Animator.AnimatorListener listener) {
        this.listener = listener;
        return this;
    }

    public ViewPropertyAnimator setUpdateListener(android.animation.ValueAnimator.AnimatorUpdateListener listener) {
        return this;
    }

    public ViewPropertyAnimator withStartAction(Runnable runnable) {
        this.startAction = runnable;
        schedule();
        return this;
    }

    public ViewPropertyAnimator withEndAction(Runnable runnable) {
        this.endAction = runnable;
        schedule();
        return this;
    }

    public ViewPropertyAnimator withLayer() {
        return this;
    }

    /** 立即执行已登记的属性变化与回调。 */
    public void start() {
        run();
    }

    /** 已登记但未执行的变化直接丢弃（与 Android 取消后停在当前值一致：当前值即尚未改变的值）。 */
    public void cancel() {
        boolean hadPending;
        synchronized (this) {
            hadPending = !pending.isEmpty() || startAction != null || endAction != null;
            pending.clear();
            startAction = null;
            endAction = null;
        }
        Animator.AnimatorListener l = listener;
        if (hadPending && l != null) l.onAnimationCancel(proxy);
    }

    private ViewPropertyAnimator add(int type, float value, boolean by) {
        synchronized (this) {
            pending.add(new float[]{type, value, by ? 1f : 0f});
        }
        schedule();
        return this;
    }

    private void schedule() {
        synchronized (this) {
            if (scheduled) return;
            scheduled = true;
        }
        view.post(this::run);
    }

    private void run() {
        List<float[]> props;
        Runnable start;
        Runnable end;
        synchronized (this) {
            scheduled = false;
            if (pending.isEmpty() && startAction == null && endAction == null) return;
            props = new ArrayList<>(pending);
            pending.clear();
            start = startAction;
            end = endAction;
            startAction = null;
            endAction = null;
        }
        Animator.AnimatorListener l = listener;
        if (start != null) start.run();
        if (l != null) l.onAnimationStart(proxy);
        for (float[] p : props) apply((int) p[0], p[1], p[2] != 0f);
        if (l != null) l.onAnimationEnd(proxy);
        if (end != null) end.run();
    }

    private void apply(int type, float value, boolean by) {
        switch (type) {
            case ALPHA:
                view.setAlpha(by ? view.getAlpha() + value : value);
                break;
            case SCALE_X:
                view.setScaleX(by ? view.getScaleX() + value : value);
                break;
            case SCALE_Y:
                view.setScaleY(by ? view.getScaleY() + value : value);
                break;
            case TRANSLATION_X:
                view.setTranslationX(by ? view.getTranslationX() + value : value);
                break;
            case TRANSLATION_Y:
                view.setTranslationY(by ? view.getTranslationY() + value : value);
                break;
            case TRANSLATION_Z:
                view.setTranslationZ(value);
                break;
            case ROTATION:
                view.setRotation(by ? view.getRotation() + value : value);
                break;
            case ROTATION_X:
                view.setRotationX(value);
                break;
            case ROTATION_Y:
                view.setRotationY(value);
                break;
            case X:
                view.setX(value);
                break;
            case Y:
                view.setY(value);
                break;
            default:
                break;
        }
    }
}
