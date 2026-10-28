package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * android.widget.ScrollView：纵向滚动容器。宿主渲染为可滚动区域，滚动位置不回传。
 */
public class ScrollView extends FrameLayout {

    public ScrollView(Context context) {
        super(context);
    }

    public ScrollView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public ScrollView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void setFillViewport(boolean fillViewport) {
    }

    public void smoothScrollTo(int x, int y) {
    }

    public boolean fullScroll(int direction) {
        return true;
    }

    public void setSmoothScrollingEnabled(boolean smoothScrollingEnabled) {
    }
}
