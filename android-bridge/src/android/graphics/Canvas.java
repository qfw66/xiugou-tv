package android.graphics;

import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Shape;
import java.awt.geom.AffineTransform;
import java.awt.geom.Arc2D;
import java.awt.geom.Ellipse2D;
import java.awt.geom.Line2D;
import java.awt.geom.Rectangle2D;
import java.awt.geom.RoundRectangle2D;
import java.util.ArrayDeque;
import java.util.Deque;

/**
 * android.graphics.Canvas：用 Java2D 直接在 {@link Bitmap} 的像素上绘制。
 *
 * <p>没有目标位图的 Canvas（例如自定义控件的 {@code onDraw}）所有绘制调用都是空操作。
 */
public class Canvas {

    private Bitmap bitmap;
    private Graphics2D g;
    private final Deque<AffineTransform> saved = new ArrayDeque<>();
    private final Deque<Shape> savedClips = new ArrayDeque<>();

    public Canvas() {
    }

    public Canvas(Bitmap bitmap) {
        setBitmap(bitmap);
    }

    public void setBitmap(Bitmap bitmap) {
        if (g != null) g.dispose();
        this.bitmap = bitmap;
        this.g = bitmap == null ? null : bitmap.image().createGraphics();
        saved.clear();
        savedClips.clear();
    }

    public int getWidth() {
        return bitmap == null ? 0 : bitmap.getWidth();
    }

    public int getHeight() {
        return bitmap == null ? 0 : bitmap.getHeight();
    }

    // ---- 变换与裁剪 ----

    public int save() {
        if (g != null) {
            saved.push(g.getTransform());
            savedClips.push(g.getClip() == null ? new Rectangle2D.Float(0, 0, getWidth(), getHeight()) : g.getClip());
        }
        return saved.size();
    }

    public void restore() {
        if (g != null && !saved.isEmpty()) {
            g.setTransform(saved.pop());
            g.setClip(savedClips.pop());
        }
    }

    public void restoreToCount(int saveCount) {
        while (saved.size() >= saveCount && !saved.isEmpty()) restore();
    }

    public int getSaveCount() {
        return saved.size();
    }

    public void translate(float dx, float dy) {
        if (g != null) g.translate(dx, dy);
    }

    public void scale(float sx, float sy) {
        if (g != null) g.scale(sx, sy);
    }

    public void rotate(float degrees) {
        if (g != null) g.rotate(Math.toRadians(degrees));
    }

    public void rotate(float degrees, float px, float py) {
        if (g != null) g.rotate(Math.toRadians(degrees), px, py);
    }

    public void concat(Matrix matrix) {
        if (g != null && matrix != null) g.transform(matrix.toAffine());
    }

    public boolean clipRect(float left, float top, float right, float bottom) {
        if (g != null) g.clip(new Rectangle2D.Float(left, top, right - left, bottom - top));
        return true;
    }

    public boolean clipRect(RectF rect) {
        return clipRect(rect.left, rect.top, rect.right, rect.bottom);
    }

    public boolean clipRect(Rect rect) {
        return clipRect(rect.left, rect.top, rect.right, rect.bottom);
    }

    public boolean clipPath(Path path) {
        if (g != null && path != null) g.clip(path.toShape());
        return true;
    }

    // ---- 绘制 ----

    public void drawColor(int color) {
        if (g == null) return;
        java.awt.Composite c = g.getComposite();
        g.setComposite(java.awt.AlphaComposite.Src);
        g.setColor(new java.awt.Color(color, true));
        g.fillRect(0, 0, getWidth(), getHeight());
        g.setComposite(c);
        bitmap.touch();
    }

    public void drawColor(int color, PorterDuff.Mode mode) {
        if (g == null) return;
        if (mode == PorterDuff.Mode.CLEAR) {
            drawColor(Color.TRANSPARENT);
            return;
        }
        if (mode == PorterDuff.Mode.SRC) {
            drawColor(color);
            return;
        }
        g.setColor(new java.awt.Color(color, true));
        g.fillRect(0, 0, getWidth(), getHeight());
        bitmap.touch();
    }

    public void drawARGB(int a, int r, int gr, int b) {
        drawColor(Color.argb(a, r, gr, b), PorterDuff.Mode.SRC_OVER);
    }

    public void drawRGB(int r, int gr, int b) {
        drawColor(Color.rgb(r, gr, b), PorterDuff.Mode.SRC_OVER);
    }

    public void drawPaint(Paint paint) {
        fillOrStroke(new Rectangle2D.Float(0, 0, getWidth(), getHeight()), paint);
    }

    public void drawRect(float left, float top, float right, float bottom, Paint paint) {
        fillOrStroke(new Rectangle2D.Float(left, top, right - left, bottom - top), paint);
    }

    public void drawRect(RectF rect, Paint paint) {
        drawRect(rect.left, rect.top, rect.right, rect.bottom, paint);
    }

    public void drawRect(Rect rect, Paint paint) {
        drawRect(rect.left, rect.top, rect.right, rect.bottom, paint);
    }

    public void drawRoundRect(RectF rect, float rx, float ry, Paint paint) {
        drawRoundRect(rect.left, rect.top, rect.right, rect.bottom, rx, ry, paint);
    }

    public void drawRoundRect(float left, float top, float right, float bottom, float rx, float ry, Paint paint) {
        fillOrStroke(new RoundRectangle2D.Float(left, top, right - left, bottom - top, rx * 2, ry * 2), paint);
    }

    public void drawCircle(float cx, float cy, float radius, Paint paint) {
        fillOrStroke(new Ellipse2D.Float(cx - radius, cy - radius, radius * 2, radius * 2), paint);
    }

    public void drawOval(RectF oval, Paint paint) {
        fillOrStroke(new Ellipse2D.Float(oval.left, oval.top, oval.width(), oval.height()), paint);
    }

    public void drawOval(float left, float top, float right, float bottom, Paint paint) {
        drawOval(new RectF(left, top, right, bottom), paint);
    }

    public void drawArc(RectF oval, float startAngle, float sweepAngle, boolean useCenter, Paint paint) {
        // Android 角度从 3 点钟方向顺时针，Java2D 逆时针，取反
        fillOrStroke(new Arc2D.Float(oval.left, oval.top, oval.width(), oval.height(), -startAngle, -sweepAngle,
                useCenter ? Arc2D.PIE : Arc2D.OPEN), paint);
    }

    public void drawLine(float startX, float startY, float stopX, float stopY, Paint paint) {
        if (g == null || paint == null) return;
        prepare(paint);
        g.setStroke(paint.awtStroke());
        g.draw(new Line2D.Float(startX, startY, stopX, stopY));
        bitmap.touch();
    }

    public void drawPath(Path path, Paint paint) {
        if (path != null) fillOrStroke(path.toShape(), paint);
    }

    public void drawText(String text, float x, float y, Paint paint) {
        if (g == null || paint == null || text == null || text.isEmpty()) return;
        prepare(paint);
        g.setFont(paint.awtFont());
        float width = paint.measureText(text);
        float startX = paint.getTextAlign() == Paint.Align.CENTER ? x - width / 2
                : paint.getTextAlign() == Paint.Align.RIGHT ? x - width : x;
        g.drawString(text, startX, y);
        bitmap.touch();
    }

    public void drawText(CharSequence text, int start, int end, float x, float y, Paint paint) {
        if (text != null) drawText(text.subSequence(start, end).toString(), x, y, paint);
    }

    public void drawBitmap(Bitmap src, float left, float top, Paint paint) {
        if (g == null || src == null) return;
        g.drawImage(src.image(), Math.round(left), Math.round(top), null);
        bitmap.touch();
    }

    public void drawBitmap(Bitmap src, Rect from, Rect to, Paint paint) {
        if (g == null || src == null || to == null) return;
        Rect s = from == null ? new Rect(0, 0, src.getWidth(), src.getHeight()) : from;
        g.drawImage(src.image(), to.left, to.top, to.right, to.bottom, s.left, s.top, s.right, s.bottom, null);
        bitmap.touch();
    }

    public void drawBitmap(Bitmap src, Rect from, RectF to, Paint paint) {
        if (to == null) return;
        drawBitmap(src, from, new Rect(Math.round(to.left), Math.round(to.top),
                Math.round(to.right), Math.round(to.bottom)), paint);
    }

    public void drawBitmap(Bitmap src, Matrix matrix, Paint paint) {
        if (g == null || src == null) return;
        g.drawImage(src.image(), matrix == null ? new AffineTransform() : matrix.toAffine(), null);
        bitmap.touch();
    }

    private void fillOrStroke(Shape shape, Paint paint) {
        if (g == null || paint == null) return;
        prepare(paint);
        Paint.Style style = paint.getStyle();
        if (style == Paint.Style.FILL || style == Paint.Style.FILL_AND_STROKE) g.fill(shape);
        if (style == Paint.Style.STROKE || style == Paint.Style.FILL_AND_STROKE) {
            g.setStroke(paint.awtStroke());
            g.draw(shape);
        }
        bitmap.touch();
    }

    private void prepare(Paint paint) {
        Object aa = paint.isAntiAlias() ? RenderingHints.VALUE_ANTIALIAS_ON : RenderingHints.VALUE_ANTIALIAS_OFF;
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, aa);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, paint.isAntiAlias()
                ? RenderingHints.VALUE_TEXT_ANTIALIAS_ON : RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        g.setPaint(paint.awtPaint());
    }
}
