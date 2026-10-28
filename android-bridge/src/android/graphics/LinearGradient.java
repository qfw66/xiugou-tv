package android.graphics;

import java.awt.MultipleGradientPaint;
import java.awt.geom.Point2D;

/**
 * android.graphics.LinearGradient：映射为 Java2D 的 {@link java.awt.LinearGradientPaint}。
 */
public class LinearGradient extends Shader {

    private final float x0;
    private final float y0;
    private final float x1;
    private final float y1;
    private final int[] colors;
    private final float[] positions;
    private final TileMode tile;

    public LinearGradient(float x0, float y0, float x1, float y1, int color0, int color1, TileMode tile) {
        this(x0, y0, x1, y1, new int[]{color0, color1}, null, tile);
    }

    public LinearGradient(float x0, float y0, float x1, float y1, int[] colors, float[] positions, TileMode tile) {
        this.x0 = x0;
        this.y0 = y0;
        this.x1 = x1;
        this.y1 = y1;
        this.colors = colors == null || colors.length < 2 ? new int[]{0, 0} : colors.clone();
        this.positions = positions == null ? null : positions.clone();
        this.tile = tile == null ? TileMode.CLAMP : tile;
    }

    @Override
    java.awt.Paint toAwtPaint() {
        if (x0 == x1 && y0 == y1) return new java.awt.Color(colors[0], true);
        int n = colors.length;
        float[] fractions = new float[n];
        java.awt.Color[] awtColors = new java.awt.Color[n];
        float last = -1f;
        for (int i = 0; i < n; i++) {
            float f = positions != null && i < positions.length ? positions[i] : (float) i / (n - 1);
            // LinearGradientPaint 要求分段点严格递增
            f = Math.max(f, last + 1e-4f);
            fractions[i] = Math.min(f, 1f);
            last = fractions[i];
            awtColors[i] = new java.awt.Color(colors[i], true);
        }
        MultipleGradientPaint.CycleMethod cycle = tile == TileMode.REPEAT
                ? MultipleGradientPaint.CycleMethod.REPEAT
                : tile == TileMode.MIRROR ? MultipleGradientPaint.CycleMethod.REFLECT
                : MultipleGradientPaint.CycleMethod.NO_CYCLE;
        try {
            return new java.awt.LinearGradientPaint(new Point2D.Float(x0, y0), new Point2D.Float(x1, y1),
                    fractions, awtColors, cycle);
        } catch (IllegalArgumentException e) {
            return awtColors[0];
        }
    }
}
