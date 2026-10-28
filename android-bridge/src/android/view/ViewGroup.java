package android.view;

import android.content.Context;
import android.util.AttributeSet;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * android.view.ViewGroup 的桌面实现：真实维护子控件列表（宿主按它序列化弹窗内容），不做测量与布局。
 */
public class ViewGroup extends View implements ViewParent {

    /** 宿主线程读快照时载荷线程可能还在 addView，用写时复制避免并发修改异常。 */
    private final List<View> children = new CopyOnWriteArrayList<>();

    public ViewGroup(Context context) {
        super(context);
    }

    public ViewGroup(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public ViewGroup(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void addView(View child) {
        addView(child, -1, null);
    }

    public void addView(View child, int index) {
        addView(child, index, null);
    }

    public void addView(View child, LayoutParams params) {
        addView(child, -1, params);
    }

    public void addView(View child, int width, int height) {
        addView(child, -1, new LayoutParams(width, height));
    }

    public void addView(View child, int index, LayoutParams params) {
        if (child == null) return;
        ViewParent old = child.getParent();
        if (old instanceof ViewGroup && old != this) ((ViewGroup) old).removeView(child);
        children.remove(child);
        if (params != null) child.setLayoutParams(params);
        if (index < 0 || index > children.size()) children.add(child);
        else children.add(index, child);
        child.assignParent(this);
        if (isAttachedToWindow()) child.dispatchAttached(true);
        notifyChanged();
    }

    public void removeView(View view) {
        if (view != null && children.remove(view)) {
            view.assignParent(null);
            view.dispatchAttached(false);
            notifyChanged();
        }
    }

    public void removeViewAt(int index) {
        if (index >= 0 && index < children.size()) removeView(children.get(index));
    }

    public void removeAllViews() {
        for (View child : children) {
            child.assignParent(null);
            child.dispatchAttached(false);
        }
        children.clear();
        notifyChanged();
    }

    public int getChildCount() {
        return children.size();
    }

    public View getChildAt(int index) {
        return index >= 0 && index < children.size() ? children.get(index) : null;
    }

    public int indexOfChild(View child) {
        return children.indexOf(child);
    }

    @Override
    public View findViewById(int id) {
        View self = super.findViewById(id);
        if (self != null) return self;
        for (View child : children) {
            View found = child.findViewById(id);
            if (found != null) return found;
        }
        return null;
    }

    @Override
    public View findViewWithTag(Object tag) {
        View self = super.findViewWithTag(tag);
        if (self != null) return self;
        for (View child : children) {
            View found = child.findViewWithTag(tag);
            if (found != null) return found;
        }
        return null;
    }

    @Override
    public void dispatchAttached(boolean attached) {
        super.dispatchAttached(attached);
        for (View child : children) child.dispatchAttached(attached);
    }

    public void measureChildren(int widthMeasureSpec, int heightMeasureSpec) {
    }

    public void setClipToPadding(boolean clip) {
    }

    public void setClipChildren(boolean clip) {
    }

    public static class LayoutParams {
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;
        public static final int FILL_PARENT = -1;

        public int width;
        public int height;

        public LayoutParams(int width, int height) {
            this.width = width;
            this.height = height;
        }

        public LayoutParams(LayoutParams source) {
            this(source.width, source.height);
        }

        public LayoutParams(Context c, AttributeSet attrs) {
        }
    }

    public static class MarginLayoutParams extends LayoutParams {
        public int leftMargin;
        public int topMargin;
        public int rightMargin;
        public int bottomMargin;

        public MarginLayoutParams(int width, int height) {
            super(width, height);
        }

        public MarginLayoutParams(LayoutParams source) {
            super(source.width, source.height);
        }

        public MarginLayoutParams(MarginLayoutParams source) {
            super(source.width, source.height);
            this.leftMargin = source.leftMargin;
            this.topMargin = source.topMargin;
            this.rightMargin = source.rightMargin;
            this.bottomMargin = source.bottomMargin;
        }

        public void setMargins(int left, int top, int right, int bottom) {
            this.leftMargin = left;
            this.topMargin = top;
            this.rightMargin = right;
            this.bottomMargin = bottom;
        }
    }
}
