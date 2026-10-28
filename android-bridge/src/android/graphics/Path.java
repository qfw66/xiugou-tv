package android.graphics;

import java.awt.geom.Arc2D;
import java.awt.geom.Ellipse2D;
import java.awt.geom.Path2D;
import java.awt.geom.Rectangle2D;
import java.awt.geom.RoundRectangle2D;

/**
 * android.graphics.Path：以 {@link Path2D} 实现。
 */
public class Path {

    public enum Direction {
        CW,
        CCW
    }

    public enum FillType {
        WINDING,
        EVEN_ODD,
        INVERSE_WINDING,
        INVERSE_EVEN_ODD
    }

    private final Path2D.Float shape = new Path2D.Float();

    public Path() {
    }

    public Path(Path src) {
        if (src != null) shape.append(src.shape, false);
    }

    /** 供 {@link Canvas} 绘制。 */
    java.awt.Shape toShape() {
        return shape;
    }

    public void reset() {
        shape.reset();
    }

    public void rewind() {
        shape.reset();
    }

    public void setFillType(FillType ft) {
        shape.setWindingRule(ft == FillType.EVEN_ODD || ft == FillType.INVERSE_EVEN_ODD
                ? Path2D.WIND_EVEN_ODD : Path2D.WIND_NON_ZERO);
    }

    public void moveTo(float x, float y) {
        shape.moveTo(x, y);
    }

    public void lineTo(float x, float y) {
        ensureStarted();
        shape.lineTo(x, y);
    }

    public void quadTo(float x1, float y1, float x2, float y2) {
        ensureStarted();
        shape.quadTo(x1, y1, x2, y2);
    }

    public void cubicTo(float x1, float y1, float x2, float y2, float x3, float y3) {
        ensureStarted();
        shape.curveTo(x1, y1, x2, y2, x3, y3);
    }

    public void close() {
        if (shape.getCurrentPoint() != null) shape.closePath();
    }

    public void addRect(RectF rect, Direction dir) {
        addRect(rect.left, rect.top, rect.right, rect.bottom, dir);
    }

    public void addRect(float left, float top, float right, float bottom, Direction dir) {
        shape.append(new Rectangle2D.Float(left, top, right - left, bottom - top), false);
    }

    public void addRoundRect(RectF rect, float rx, float ry, Direction dir) {
        shape.append(new RoundRectangle2D.Float(rect.left, rect.top, rect.width(), rect.height(),
                rx * 2, ry * 2), false);
    }

    public void addCircle(float x, float y, float radius, Direction dir) {
        shape.append(new Ellipse2D.Float(x - radius, y - radius, radius * 2, radius * 2), false);
    }

    public void addOval(RectF oval, Direction dir) {
        shape.append(new Ellipse2D.Float(oval.left, oval.top, oval.width(), oval.height()), false);
    }

    public void addArc(RectF oval, float startAngle, float sweepAngle) {
        // Android 角度从 3 点钟方向顺时针，Java2D 逆时针，取反。
        shape.append(new Arc2D.Float(oval.left, oval.top, oval.width(), oval.height(),
                -startAngle, -sweepAngle, Arc2D.OPEN), false);
    }

    private void ensureStarted() {
        // Android 允许不先 moveTo 就 lineTo（从原点起笔），Path2D 会抛异常。
        if (shape.getCurrentPoint() == null) shape.moveTo(0, 0);
    }
}
