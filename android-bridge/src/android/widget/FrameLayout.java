package android.widget;

import android.content.Context;
import android.view.ViewGroup;

/**
 * Minimal android.widget.FrameLayout stub。
 */
public class FrameLayout extends ViewGroup {

    public FrameLayout(Context context) {
        super(context);
    }

    public void setForegroundGravity(int gravity) {
    }

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public int gravity;

        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(ViewGroup.MarginLayoutParams source) {
            super(source);
        }
    }
}
