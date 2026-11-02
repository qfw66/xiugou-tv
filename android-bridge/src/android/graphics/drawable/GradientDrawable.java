package android.graphics.drawable;

/**
 * Minimal android.graphics.drawable.GradientDrawable stub。
 *
 * <p>补齐理由（2026-10-18）：wexguard 载荷（配置 newwex.json 的
 * {@code csp_NewDouBanGuard}）在 {@code InitOrigin.init} 阶段抛
 * {@code NoClassDefFoundError: android/graphics/drawable/GradientDrawable}，
 * 导致框架初始化不完整。这里只补「能让类加载与静态初始化通过」的最小面：
 * 常量 + 属性 setter，全部无状态（不设静态可变字段），避免跨站点互相污染。
 *
 * <p>纪律：只补被真实站点触发、且日志能指名的类；缺什么补什么，不批量照搬 AOSP。
 */
public class GradientDrawable extends Drawable {

    /** 与 AOSP 对齐的形状常量。 */
    public static final int RECTANGLE = 0;
    public static final int OVAL = 1;
    public static final int LINE = 2;
    public static final int RING = 3;

    /** 渐变方向（与 AOSP 一样是枚举，载荷以 GETSTATIC 取枚举实例）。 */
    public enum Orientation {
        TOP_BOTTOM,
        TR_BL,
        RIGHT_LEFT,
        BR_TL,
        BOTTOM_TOP,
        BL_TR,
        LEFT_RIGHT,
        TL_BR
    }

    private Orientation orientation = Orientation.TOP_BOTTOM;
    private int[] colors;

    /** 线性渐变 / 径向渐变 / 扫描渐变（AOSP 取值）。 */
    public static final int LINEAR_GRADIENT = 0;
    public static final int RADIAL_GRADIENT = 1;
    public static final int SWEEP_GRADIENT = 2;

    public GradientDrawable() {
    }

    public GradientDrawable(Orientation orientation, int[] colors) {
        if (orientation != null) this.orientation = orientation;
        this.colors = colors == null ? null : colors.clone();
    }

    public void setShape(int shape) {
    }

    public void setColor(int argb) {
    }

    public void setColors(int[] colors) {
        this.colors = colors == null ? null : colors.clone();
    }

    public int[] getColors() {
        return colors == null ? null : colors.clone();
    }

    public void setCornerRadius(float radius) {
    }

    public void setCornerRadii(float[] radii) {
    }

    public void setStroke(int width, int color) {
    }

    public void setStroke(int width, int color, float dashWidth, float dashGap) {
    }

    public void setGradientType(int gradient) {
    }

    public void setOrientation(Orientation orientation) {
        if (orientation != null) this.orientation = orientation;
    }

    public Orientation getOrientation() {
        return orientation;
    }

    public void setSize(int width, int height) {
    }

    public void setUseLevel(boolean useLevel) {
    }

    public int getOpacity() {
        return 0;
    }

    @Override
    public void setAlpha(int alpha) {
    }

    @Override
    public Drawable mutate() {
        return this;
    }
}
