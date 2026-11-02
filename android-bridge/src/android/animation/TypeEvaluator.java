package android.animation;

/**
 * 属性动画的取值计算器。
 */
public interface TypeEvaluator<T> {
    T evaluate(float fraction, T startValue, T endValue);
}
