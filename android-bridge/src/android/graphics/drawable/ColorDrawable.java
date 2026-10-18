package android.graphics.drawable;

/**
 * Minimal android.graphics.drawable.ColorDrawable stub。
 */
public class ColorDrawable extends Drawable {

    private int color;

    public ColorDrawable() {
    }

    public ColorDrawable(int color) {
        this.color = color;
    }

    public void setColor(int color) {
        this.color = color;
    }

    public int getColor() {
        return color;
    }
}
