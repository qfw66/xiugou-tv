package android.content.res;

/**
 * android.content.res.ColorStateList：按状态取色；桌面端只保存默认色（列表最后一项，通常是兜底状态）。
 */
public class ColorStateList {

    private final int[][] states;
    private final int[] colors;

    public ColorStateList(int[][] states, int[] colors) {
        this.states = states == null ? new int[0][] : states;
        this.colors = colors == null ? new int[0] : colors.clone();
    }

    public static ColorStateList valueOf(int color) {
        return new ColorStateList(new int[][]{new int[0]}, new int[]{color});
    }

    public int getDefaultColor() {
        return colors.length == 0 ? 0xFF000000 : colors[colors.length - 1];
    }

    public int getColorForState(int[] stateSet, int defaultColor) {
        return colors.length == 0 ? defaultColor : getDefaultColor();
    }

    public boolean isStateful() {
        return states.length > 1;
    }
}
