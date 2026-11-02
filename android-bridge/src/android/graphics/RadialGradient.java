package android.graphics;

import java.awt.MultipleGradientPaint;
import java.awt.geom.Point2D;

/**
 * android.graphics.RadialGradient：映射为 Java2D 的 {@link java.awt.RadialGradientPaint}。
 *
 * <p>桌面端并不真的画图，这个类存在的意义是「让载荷的链接期不炸」：
 * 部分直播站点（如 GuaziLive）在 {@code init} 里就 new 一个径向渐变当占位，
 * 缺类会直接 {@code ClassNotFoundException} 把整站拖死。
 */
public class RadialGradient extends Shader {

    private final float centerX;
    private final float centerY;
    private final float radius;
    private final int[] colors;
    private final float[] positions;
    private final TileMode tile;

    public RadialGradient(float centerX, float centerY, float radius,
                          int centerColor, int edgeColor, TileMode tile) {
        this(centerX, centerY, radius, new int[]{centerColor, edgeColor}, null, tile);
    }

    public RadialGradient(float centerX, float centerY, float radius,
                          int[] colors, float[] positions, TileMode tile) {
        this.centerX = centerX;
        this.centerY = centerY;
        this.radius = radius;
        this.colors = colors == null || colors.length < 2 ? new int[]{0, 0} : colors.clone();
        this.positions = positions == null ? null : positions.clone();
        this.tile = tile == null ? TileMode.CLAMP : tile;
    }

    @Override
    java.awt.Paint toAwtPaint() {
        if (radius <= 0f || colors.length < 2) return new java.awt.Color(colors[0], true);
        int n = colors.length;
        float[] fractions = new float[n];
        java.awt.Color[] awtColors = new java.awt.Color[n];
        float last = -1f;
        for (int i = 0; i < n; i++) {
            float f = positions != null && i < positions.length ? positions[i] : (float) i / (n - 1);
            // RadialGradientPaint 同样要求分段点严格递增
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
            return new java.awt.RadialGradientPaint(new Point2D.Float(centerX, centerY),
                    Math.max(radius, 1e-3f), new Point2D.Float(centerX, centerY),
                    fractions, awtColors, cycle);
        } catch (IllegalArgumentException e) {
            return awtColors[0];
        }
    }
}
