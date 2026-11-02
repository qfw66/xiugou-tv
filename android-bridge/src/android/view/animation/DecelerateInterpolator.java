package android.view.animation;

import android.content.Context;
import android.util.AttributeSet;

/**
 * 减速插值：factor 为 1 时是 1-(1-t)²，否则 1-(1-t)^(2·factor)，与 AOSP 公式一致。
 */
public class DecelerateInterpolator extends BaseInterpolator {

    private final float factor;

    public DecelerateInterpolator() {
        this(1.0f);
    }

    public DecelerateInterpolator(float factor) {
        this.factor = factor;
    }

    public DecelerateInterpolator(Context context, AttributeSet attrs) {
        this();
    }

    @Override
    public float getInterpolation(float input) {
        if (factor == 1.0f) return 1.0f - (1.0f - input) * (1.0f - input);
        return (float) (1.0f - Math.pow(1.0f - input, 2.0 * factor));
    }
}
