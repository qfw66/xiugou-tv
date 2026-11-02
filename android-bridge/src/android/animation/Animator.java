package android.animation;

import java.util.ArrayList;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * android.animation.Animator 的桌面实现。
 *
 * <p>桌面端没有帧循环：{@link #start()} 立即把动画推进到终值，并按 Android 的顺序回调
 * onAnimationStart、（子类更新目标）、onAnimationEnd。弹窗的显隐 / 淡入等最终状态因此与 Android 一致，
 * 只是没有过渡过程。
 */
public abstract class Animator implements Cloneable {

    public static final long DURATION_INFINITE = -1;

    private CopyOnWriteArrayList<AnimatorListener> listeners = new CopyOnWriteArrayList<>();
    private boolean running;
    private boolean started;
    /** 防止在 onAnimationEnd 里重新 start() 自身导致无限递归（循环动画常这么写）。 */
    private boolean dispatching;
    private long startDelay;
    private TimeInterpolator interpolator;

    public void start() {
        if (dispatching) return;
        dispatching = true;
        try {
            started = true;
            running = true;
            for (AnimatorListener l : listeners) l.onAnimationStart(this, false);
            // 在 onAnimationStart 里被取消时不再推进；Android 在取消后同样会回调 onAnimationEnd
            if (running) onJumpToEnd();
            running = false;
            started = false;
            for (AnimatorListener l : listeners) l.onAnimationEnd(this, false);
        } finally {
            dispatching = false;
        }
    }

    /** 子类在这里把目标推进到终值（桌面扩展，不是 Android API）。 */
    protected void onJumpToEnd() {
    }

    /** 动画总在 start() 内同步结束，只有回调期间才处于运行中；此时取消按 Android 语义回调 onAnimationCancel。 */
    public void cancel() {
        if (!running) return;
        running = false;
        for (AnimatorListener l : listeners) l.onAnimationCancel(this);
    }

    /** 未启动时 Android 会先启动再结束，效果就是直接到终值。 */
    public void end() {
        if (!started) start();
    }

    public void pause() {
    }

    public void resume() {
    }

    public boolean isPaused() {
        return false;
    }

    public boolean isRunning() {
        return running;
    }

    public boolean isStarted() {
        return started;
    }

    public long getStartDelay() {
        return startDelay;
    }

    public void setStartDelay(long startDelay) {
        this.startDelay = startDelay;
    }

    public abstract Animator setDuration(long duration);

    public abstract long getDuration();

    public long getTotalDuration() {
        return startDelay + getDuration();
    }

    public void setInterpolator(TimeInterpolator value) {
        this.interpolator = value;
    }

    public TimeInterpolator getInterpolator() {
        return interpolator;
    }

    public void addListener(AnimatorListener listener) {
        if (listener != null) listeners.add(listener);
    }

    public void removeListener(AnimatorListener listener) {
        listeners.remove(listener);
    }

    public ArrayList<AnimatorListener> getListeners() {
        return listeners.isEmpty() ? null : new ArrayList<>(listeners);
    }

    public void removeAllListeners() {
        listeners.clear();
    }

    public void addPauseListener(AnimatorPauseListener listener) {
    }

    public void removePauseListener(AnimatorPauseListener listener) {
    }

    public void setTarget(Object target) {
    }

    public void setupStartValues() {
    }

    public void setupEndValues() {
    }

    @Override
    public Animator clone() {
        try {
            Animator copy = (Animator) super.clone();
            copy.listeners = new CopyOnWriteArrayList<>(listeners);
            copy.running = false;
            copy.started = false;
            copy.dispatching = false;
            return copy;
        } catch (CloneNotSupportedException e) {
            throw new AssertionError(e);
        }
    }

    public interface AnimatorListener {
        default void onAnimationStart(Animator animation, boolean isReverse) {
            onAnimationStart(animation);
        }

        default void onAnimationEnd(Animator animation, boolean isReverse) {
            onAnimationEnd(animation);
        }

        void onAnimationStart(Animator animation);

        void onAnimationEnd(Animator animation);

        void onAnimationCancel(Animator animation);

        void onAnimationRepeat(Animator animation);
    }

    public interface AnimatorPauseListener {
        void onAnimationPause(Animator animation);

        void onAnimationResume(Animator animation);
    }
}
