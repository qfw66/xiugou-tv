package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * android.widget.HorizontalScrollView：横向滚动容器。
 */
public class HorizontalScrollView extends FrameLayout {

    public HorizontalScrollView(Context context) {
        super(context);
    }

    public HorizontalScrollView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public HorizontalScrollView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    private boolean smoothScrollingEnabled = true;

    public void setFillViewport(boolean fillViewport) {
    }

    public void setSmoothScrollingEnabled(boolean smoothScrollingEnabled) {
        this.smoothScrollingEnabled = smoothScrollingEnabled;
    }

    public boolean isSmoothScrollingEnabled() {
        return smoothScrollingEnabled;
    }

    public void smoothScrollTo(int x, int y) {
    }

    public boolean fullScroll(int direction) {
        return true;
    }
}
