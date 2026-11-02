package android.graphics;

import java.awt.PaintContext;
import java.awt.Rectangle;
import java.awt.RenderingHints;
import java.awt.geom.AffineTransform;
import java.awt.geom.Rectangle2D;
import java.awt.image.ColorModel;
import java.awt.image.Raster;
import java.awt.image.WritableRaster;

/**
 * android.graphics.SweepGradient：绕中心点按角度（从 3 点钟方向顺时针）渐变。
 * Java2D 没有对应画笔，这里用自定义 {@link java.awt.Paint} 逐像素按角度插值。
 */
public class SweepGradient extends Shader {

    private final float cx;
    private final float cy;
    private final int[] colors;
    private final float[] positions;

    public SweepGradient(float cx, float cy, int[] colors, float[] positions) {
        if (colors == null || colors.length < 2) throw new IllegalArgumentException("needs >= 2 number of colors");
        if (positions != null && positions.length != colors.length) {
            throw new IllegalArgumentException("color and position arrays must be of equal length");
        }
        this.cx = cx;
        this.cy = cy;
        this.colors = colors.clone();
        this.positions = positions == null ? null : positions.clone();
    }

    public SweepGradient(float cx, float cy, int color0, int color1) {
        this(cx, cy, new int[]{color0, color1}, null);
    }

    /** 角度比例 t∈[0,1] 处的颜色。 */
    int colorAt(float t) {
        int n = colors.length;
        for (int i = 0; i < n - 1; i++) {
            float p0 = positions != null ? positions[i] : (float) i / (n - 1);
            float p1 = positions != null ? positions[i + 1] : (float) (i + 1) / (n - 1);
            if (t <= p1 || i == n - 2) {
                float local = p1 <= p0 ? 0f : Math.max(0f, Math.min(1f, (t - p0) / (p1 - p0)));
                return lerp(colors[i], colors[i + 1], local);
            }
        }
        return colors[n - 1];
    }

    private static int lerp(int a, int b, float f) {
        int ca = (int) ((a >>> 24) + ((b >>> 24) - (a >>> 24)) * f);
        int cr = (int) (((a >> 16) & 0xFF) + (((b >> 16) & 0xFF) - ((a >> 16) & 0xFF)) * f);
        int cg = (int) (((a >> 8) & 0xFF) + (((b >> 8) & 0xFF) - ((a >> 8) & 0xFF)) * f);
        int cb = (int) ((a & 0xFF) + ((b & 0xFF) - (a & 0xFF)) * f);
        return (ca << 24) | (cr << 16) | (cg << 8) | cb;
    }

    @Override
    java.awt.Paint toAwtPaint() {
        return new java.awt.Paint() {
            @Override
            public PaintContext createContext(ColorModel cm, Rectangle deviceBounds, Rectangle2D userBounds,
                                              AffineTransform xform, RenderingHints hints) {
                AffineTransform inverse;
                try {
                    inverse = xform.createInverse();
                } catch (java.awt.geom.NoninvertibleTransformException e) {
                    inverse = new AffineTransform();
                }
                AffineTransform toUser = inverse;
                ColorModel model = ColorModel.getRGBdefault();
                return new PaintContext() {
                    @Override
                    public void dispose() {
                    }

                    @Override
                    public ColorModel getColorModel() {
                        return model;
                    }

                    @Override
                    public Raster getRaster(int x, int y, int w, int h) {
                        WritableRaster raster = model.createCompatibleWritableRaster(w, h);
                        int[] row = new int[w];
                        java.awt.geom.Point2D.Float pt = new java.awt.geom.Point2D.Float();
                        for (int j = 0; j < h; j++) {
                            for (int i = 0; i < w; i++) {
                                pt.setLocation(x + i + 0.5f, y + j + 0.5f);
                                toUser.transform(pt, pt);
                                double angle = Math.atan2(pt.y - cy, pt.x - cx);
                                if (angle < 0) angle += Math.PI * 2;
                                row[i] = colorAt((float) (angle / (Math.PI * 2)));
                            }
                            raster.setDataElements(0, j, w, 1, row);
                        }
                        return raster;
                    }
                };
            }

            @Override
            public int getTransparency() {
                return TRANSLUCENT;
            }
        };
    }
}
