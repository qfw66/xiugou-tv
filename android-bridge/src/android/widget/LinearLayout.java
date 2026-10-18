package android.widget;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/**
 * Minimal android.widget.LinearLayout stub。
 */
public class LinearLayout extends ViewGroup {

    public static final int HORIZONTAL = 0;
    public static final int VERTICAL = 1;

    public LinearLayout(Context context) {
        super(context);
    }

    public void setOrientation(int orientation) {
    }

    public void setGravity(int gravity) {
    }

    public void setWeightSum(float weightSum) {
    }

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public float weight;
        public int gravity;

        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(int width, int height, float weight) {
            super(width, height);
            this.weight = weight;
        }
    }
}
