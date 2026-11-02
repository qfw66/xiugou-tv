package android.view.animation;

import android.content.Context;
import android.util.AttributeSet;

/**
 * 线性插值：输出等于输入。
 */
public class LinearInterpolator extends BaseInterpolator {

    public LinearInterpolator() {
    }

    public LinearInterpolator(Context context, AttributeSet attrs) {
    }

    @Override
    public float getInterpolation(float input) {
        return input;
    }
}
