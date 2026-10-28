package android.graphics.drawable;

import android.graphics.Canvas;
import android.graphics.Rect;

/**
 * android.graphics.drawable.Drawable 的桌面实现：保存边界与透明度，不参与呈现
 * （宿主只展示 {@link BitmapDrawable} 里的位图）。
 */
public abstract class Drawable {

    private final Rect bounds = new Rect();
    private int level;

    public void setAlpha(int alpha) {
    }

    public void setColorFilter(int color, android.graphics.PorterDuff.Mode mode) {
    }

    public void setTint(int tintColor) {
    }

    public int getIntrinsicWidth() {
        return 0;
    }

    public int getIntrinsicHeight() {
        return 0;
    }

    public void setBounds(int left, int top, int right, int bottom) {
        bounds.set(left, top, right, bottom);
    }

    public void setBounds(Rect rect) {
        if (rect != null) bounds.set(rect);
    }

    public final Rect getBounds() {
        return new Rect(bounds);
    }

    public final boolean setLevel(int level) {
        if (this.level == level) return false;
        this.level = level;
        return true;
    }

    public final int getLevel() {
        return level;
    }

    public void draw(Canvas canvas) {
    }

    public Drawable mutate() {
        return this;
    }

    public ConstantState getConstantState() {
        final Drawable self = this;
        return new ConstantState() {
            @Override
            public Drawable newDrawable() {
                return self;
            }
        };
    }

    public abstract static class ConstantState {
        public abstract Drawable newDrawable();

        public Drawable newDrawable(android.content.res.Resources res) {
            return newDrawable();
        }

        public int getChangingConfigurations() {
            return 0;
        }
    }
}
