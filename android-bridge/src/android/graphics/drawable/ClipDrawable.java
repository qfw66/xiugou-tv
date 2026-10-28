package android.graphics.drawable;

/**
 * android.graphics.drawable.ClipDrawable：进度条等按 level 裁剪的包装；桌面端只保存被包装对象。
 */
public class ClipDrawable extends Drawable {

    public static final int HORIZONTAL = 1;
    public static final int VERTICAL = 2;

    private final Drawable drawable;

    public ClipDrawable(Drawable drawable, int gravity, int orientation) {
        this.drawable = drawable;
    }

    public Drawable getDrawable() {
        return drawable;
    }
}
