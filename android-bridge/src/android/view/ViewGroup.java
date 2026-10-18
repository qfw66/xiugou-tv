package android.view;

import android.content.Context;

/**
 * Minimal android.view.ViewGroup stub。
 */
public class ViewGroup extends View {

    public ViewGroup(Context context) {
        super(context);
    }

    public void addView(View child) {
    }

    public void addView(View child, LayoutParams params) {
    }

    public void removeView(View view) {
    }

    public void removeAllViews() {
    }

    public int getChildCount() {
        return 0;
    }

    public View getChildAt(int index) {
        return null;
    }

    public void setClipToPadding(boolean clip) {
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

        public LayoutParams(Context c, android.util.AttributeSet attrs) {
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

        public void setMargins(int left, int top, int right, int bottom) {
            this.leftMargin = left;
            this.topMargin = top;
            this.rightMargin = right;
            this.bottomMargin = bottom;
        }
    }
}
