package android.graphics;

/**
 * 按颜色混合模式着色的滤镜。
 */
public class PorterDuffColorFilter extends ColorFilter {

    private final int color;
    private final PorterDuff.Mode mode;

    public PorterDuffColorFilter(int color, PorterDuff.Mode mode) {
        this.color = color;
        this.mode = mode;
    }

    public int getColor() {
        return color;
    }

    public PorterDuff.Mode getMode() {
        return mode;
    }
}
