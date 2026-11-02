package android.view.animation;

import android.content.Context;
import android.util.AttributeSet;

/**
 * 加速插值：factor 为 1 时是 t²，否则 t^(2·factor)，与 AOSP 公式一致。
 */
public class AccelerateInterpolator extends BaseInterpolator {

    private final float factor;

    public AccelerateInterpolator() {
        this(1.0f);
    }

    public AccelerateInterpolator(float factor) {
        this.factor = factor;
    }

    public AccelerateInterpolator(Context context, AttributeSet attrs) {
        this();
    }

    @Override
    public float getInterpolation(float input) {
        if (factor == 1.0f) return input * input;
        return (float) Math.pow(input, 2.0 * factor);
    }
}
