package android.graphics;

/**
 * android.graphics.RectF：浮点矩形。
 */
public class RectF {

    public float left;
    public float top;
    public float right;
    public float bottom;

    public RectF() {
    }

    public RectF(float left, float top, float right, float bottom) {
        set(left, top, right, bottom);
    }

    public RectF(RectF r) {
        if (r != null) set(r.left, r.top, r.right, r.bottom);
    }

    public RectF(Rect r) {
        if (r != null) set(r.left, r.top, r.right, r.bottom);
    }

    public void set(float left, float top, float right, float bottom) {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

    public void set(RectF src) {
        set(src.left, src.top, src.right, src.bottom);
    }

    public final float width() {
        return right - left;
    }

    public final float height() {
        return bottom - top;
    }

    public final float centerX() {
        return (left + right) * 0.5f;
    }

    public final float centerY() {
        return (top + bottom) * 0.5f;
    }

    public final boolean isEmpty() {
        return left >= right || top >= bottom;
    }

    public void inset(float dx, float dy) {
        left += dx;
        top += dy;
        right -= dx;
        bottom -= dy;
    }

    public void offset(float dx, float dy) {
        left += dx;
        right += dx;
        top += dy;
        bottom += dy;
    }
}
