package android.animation;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * android.animation.ValueAnimator 的桌面实现：start() 时把进度直接置为 1、取值置为终值，
 * 回调一次 {@link AnimatorUpdateListener}，再按 {@link Animator} 的约定回调结束。
 */
public class ValueAnimator extends Animator {

    public static final int RESTART = 1;
    public static final int REVERSE = 2;
    public static final int INFINITE = -1;

    private CopyOnWriteArrayList<AnimatorUpdateListener> updateListeners = new CopyOnWriteArrayList<>();
    private float[] floatValues;
    private int[] intValues;
    private Object[] objectValues;
    private TypeEvaluator<?> evaluator;
    private long duration = 300;
    private int repeatCount;
    private int repeatMode = RESTART;
    private float fraction;
    private Object animatedValue;

    public ValueAnimator() {
    }

    public static ValueAnimator ofFloat(float... values) {
        ValueAnimator a = new ValueAnimator();
        a.setFloatValues(values);
        return a;
    }

    public static ValueAnimator ofInt(int... values) {
        ValueAnimator a = new ValueAnimator();
        a.setIntValues(values);
        return a;
    }

    public static ValueAnimator ofArgb(int... values) {
        return ofInt(values);
    }

    public static ValueAnimator ofObject(TypeEvaluator<?> evaluator, Object... values) {
        ValueAnimator a = new ValueAnimator();
        a.setObjectValues(values);
        a.setEvaluator(evaluator);
        return a;
    }

    public void setFloatValues(float... values) {
        floatValues = values == null ? null : values.clone();
        intValues = null;
        objectValues = null;
        animatedValue = valueAt(0f);
    }

    public void setIntValues(int... values) {
        intValues = values == null ? null : values.clone();
        floatValues = null;
        objectValues = null;
        animatedValue = valueAt(0f);
    }

    public void setObjectValues(Object... values) {
        objectValues = values == null ? null : values.clone();
        floatValues = null;
        intValues = null;
        animatedValue = valueAt(0f);
    }

    public void setEvaluator(TypeEvaluator<?> value) {
        this.evaluator = value;
    }

    @Override
    public ValueAnimator setDuration(long duration) {
        if (duration < 0) throw new IllegalArgumentException("Animators cannot have negative duration: " + duration);
        this.duration = duration;
        return this;
    }

    @Override
    public long getDuration() {
        return duration;
    }

    public void setRepeatCount(int value) {
        this.repeatCount = value;
    }

    public int getRepeatCount() {
        return repeatCount;
    }

    public void setRepeatMode(int value) {
        this.repeatMode = value;
    }

    public int getRepeatMode() {
        return repeatMode;
    }

    public void setCurrentPlayTime(long playTime) {
        setCurrentFraction(duration <= 0 ? 1f : (float) playTime / duration);
    }

    public long getCurrentPlayTime() {
        return (long) (fraction * duration);
    }

    /** 直接定位到指定进度并回调更新（Android 同样会立刻更新目标）。 */
    public void setCurrentFraction(float value) {
        fraction = Math.max(0f, Math.min(1f, value));
        animatedValue = valueAt(fraction);
        dispatchUpdate();
    }

    public float getAnimatedFraction() {
        return fraction;
    }

    public Object getAnimatedValue() {
        return animatedValue;
    }

    public Object getAnimatedValue(String propertyName) {
        return animatedValue;
    }

    public void addUpdateListener(AnimatorUpdateListener listener) {
        if (listener != null) updateListeners.add(listener);
    }

    public void removeUpdateListener(AnimatorUpdateListener listener) {
        updateListeners.remove(listener);
    }

    public void removeAllUpdateListeners() {
        updateListeners.clear();
    }

    /** 反向播放：交换起止值后按正常流程一步到（原来的）起点。 */
    public void reverse() {
        reverseValues();
        start();
    }

    @Override
    protected void onJumpToEnd() {
        // 往返模式重复奇数次后停在起点，其余情况停在终点；无限重复按播放一次处理
        boolean endsAtStart = repeatMode == REVERSE && repeatCount > 0 && repeatCount % 2 == 1;
        fraction = 1f;
        animatedValue = valueAt(endsAtStart ? 0f : 1f);
        dispatchUpdate();
    }

    /** 回调取值更新；{@link ObjectAnimator} 在此之前把值写回目标。 */
    protected void dispatchUpdate() {
        for (AnimatorUpdateListener l : updateListeners) l.onAnimationUpdate(this);
    }

    /** 按（插值后的）进度求当前值：多关键帧时在相邻两帧间线性插值。 */
    @SuppressWarnings({"unchecked", "rawtypes"})
    private Object valueAt(float t) {
        TimeInterpolator interpolator = getInterpolator();
        float f = interpolator == null || t == 0f || t == 1f ? t : interpolator.getInterpolation(t);
        if (floatValues != null && floatValues.length > 0) {
            if (floatValues.length == 1) return floatValues[0];
            float pos = f * (floatValues.length - 1);
            int i = Math.max(0, Math.min((int) pos, floatValues.length - 2));
            return floatValues[i] + (floatValues[i + 1] - floatValues[i]) * (pos - i);
        }
        if (intValues != null && intValues.length > 0) {
            if (intValues.length == 1) return intValues[0];
            float pos = f * (intValues.length - 1);
            int i = Math.max(0, Math.min((int) pos, intValues.length - 2));
            return (int) (intValues[i] + (intValues[i + 1] - intValues[i]) * (pos - i));
        }
        if (objectValues != null && objectValues.length > 0) {
            if (objectValues.length == 1) return objectValues[0];
            if (evaluator == null) return objectValues[f >= 1f ? objectValues.length - 1 : 0];
            float pos = f * (objectValues.length - 1);
            int i = Math.max(0, Math.min((int) pos, objectValues.length - 2));
            return ((TypeEvaluator) evaluator).evaluate(pos - i, objectValues[i], objectValues[i + 1]);
        }
        return null;
    }

    private void reverseValues() {
        if (floatValues != null) {
            for (int i = 0, j = floatValues.length - 1; i < j; i++, j--) {
                float tmp = floatValues[i];
                floatValues[i] = floatValues[j];
                floatValues[j] = tmp;
            }
        }
        if (intValues != null) {
            for (int i = 0, j = intValues.length - 1; i < j; i++, j--) {
                int tmp = intValues[i];
                intValues[i] = intValues[j];
                intValues[j] = tmp;
            }
        }
        if (objectValues != null) {
            for (int i = 0, j = objectValues.length - 1; i < j; i++, j--) {
                Object tmp = objectValues[i];
                objectValues[i] = objectValues[j];
                objectValues[j] = tmp;
            }
        }
    }

    @Override
    public ValueAnimator clone() {
        ValueAnimator copy = (ValueAnimator) super.clone();
        copy.updateListeners = new CopyOnWriteArrayList<>(updateListeners);
        if (floatValues != null) copy.floatValues = floatValues.clone();
        if (intValues != null) copy.intValues = intValues.clone();
        if (objectValues != null) copy.objectValues = objectValues.clone();
        return copy;
    }

    public interface AnimatorUpdateListener {
        void onAnimationUpdate(ValueAnimator animation);
    }
}
