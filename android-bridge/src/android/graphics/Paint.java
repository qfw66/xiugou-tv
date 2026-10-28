package android.graphics;

import java.awt.BasicStroke;
import java.awt.Font;
import java.awt.font.FontRenderContext;
import java.awt.geom.Rectangle2D;
import java.awt.image.BufferedImage;

/**
 * android.graphics.Paint：保存画笔状态，并提供对应的 Java2D 颜色 / 描边 / 字体（供 {@link Canvas} 绘制）。
 */
public class Paint {

    public static final int ANTI_ALIAS_FLAG = 0x01;
    public static final int FILTER_BITMAP_FLAG = 0x02;
    public static final int DITHER_FLAG = 0x04;
    public static final int FAKE_BOLD_TEXT_FLAG = 0x20;

    public enum Style {
        FILL,
        STROKE,
        FILL_AND_STROKE
    }

    public enum Cap {
        BUTT,
        ROUND,
        SQUARE
    }

    public enum Join {
        MITER,
        ROUND,
        BEVEL
    }

    public enum Align {
        LEFT,
        CENTER,
        RIGHT
    }

    public static class FontMetrics {
        public float top;
        public float ascent;
        public float descent;
        public float bottom;
        public float leading;
    }

    public static class FontMetricsInt {
        public int top;
        public int ascent;
        public int descent;
        public int bottom;
        public int leading;
    }

    private static final FontRenderContext FRC = new FontRenderContext(null, true, true);

    private int flags;
    private int color = Color.BLACK;
    private Style style = Style.FILL;
    private float strokeWidth;
    private Cap strokeCap = Cap.BUTT;
    private Join strokeJoin = Join.MITER;
    private float textSize = 12f;
    private Align textAlign = Align.LEFT;
    private Typeface typeface = Typeface.DEFAULT;
    private boolean fakeBold;
    private Shader shader;

    public Paint() {
    }

    public Paint(int flags) {
        this.flags = flags;
        this.fakeBold = (flags & FAKE_BOLD_TEXT_FLAG) != 0;
    }

    public Paint(Paint src) {
        set(src);
    }

    public void set(Paint src) {
        if (src == null) return;
        flags = src.flags;
        color = src.color;
        style = src.style;
        strokeWidth = src.strokeWidth;
        strokeCap = src.strokeCap;
        strokeJoin = src.strokeJoin;
        textSize = src.textSize;
        textAlign = src.textAlign;
        typeface = src.typeface;
        fakeBold = src.fakeBold;
        shader = src.shader;
    }

    public void reset() {
        set(new Paint());
    }

    public int getFlags() {
        return flags;
    }

    public void setFlags(int flags) {
        this.flags = flags;
    }

    public void setAntiAlias(boolean aa) {
        flags = aa ? flags | ANTI_ALIAS_FLAG : flags & ~ANTI_ALIAS_FLAG;
    }

    public boolean isAntiAlias() {
        return (flags & ANTI_ALIAS_FLAG) != 0;
    }

    public void setDither(boolean dither) {
    }

    public void setFilterBitmap(boolean filter) {
    }

    public void setColor(int color) {
        this.color = color;
    }

    public int getColor() {
        return color;
    }

    public void setAlpha(int a) {
        color = (color & 0x00FFFFFF) | ((a & 0xFF) << 24);
    }

    public int getAlpha() {
        return color >>> 24;
    }

    public void setARGB(int a, int r, int g, int b) {
        color = Color.argb(a, r, g, b);
    }

    public void setStyle(Style style) {
        this.style = style == null ? Style.FILL : style;
    }

    public Style getStyle() {
        return style;
    }

    public void setStrokeWidth(float width) {
        this.strokeWidth = width;
    }

    public float getStrokeWidth() {
        return strokeWidth;
    }

    public void setStrokeCap(Cap cap) {
        this.strokeCap = cap == null ? Cap.BUTT : cap;
    }

    public void setStrokeJoin(Join join) {
        this.strokeJoin = join == null ? Join.MITER : join;
    }

    public void setTextSize(float textSize) {
        if (textSize > 0) this.textSize = textSize;
    }

    public float getTextSize() {
        return textSize;
    }

    public void setTextAlign(Align align) {
        this.textAlign = align == null ? Align.LEFT : align;
    }

    public Align getTextAlign() {
        return textAlign;
    }

    public Typeface setTypeface(Typeface typeface) {
        this.typeface = typeface == null ? Typeface.DEFAULT : typeface;
        return typeface;
    }

    public Typeface getTypeface() {
        return typeface;
    }

    public void setFakeBoldText(boolean fakeBoldText) {
        this.fakeBold = fakeBoldText;
    }

    public Shader setShader(Shader shader) {
        this.shader = shader;
        return shader;
    }

    public Shader getShader() {
        return shader;
    }

    public float measureText(String text) {
        if (text == null || text.isEmpty()) return 0f;
        return (float) awtFont().getStringBounds(text, FRC).getWidth();
    }

    public float measureText(CharSequence text, int start, int end) {
        return text == null ? 0f : measureText(text.subSequence(start, end).toString());
    }

    public void getTextBounds(String text, int start, int end, Rect bounds) {
        if (bounds == null) return;
        if (text == null || start >= end) {
            bounds.setEmpty();
            return;
        }
        Rectangle2D r = awtFont().getStringBounds(text.substring(start, end), FRC);
        bounds.set((int) Math.floor(r.getX()), (int) Math.floor(r.getY()),
                (int) Math.ceil(r.getMaxX()), (int) Math.ceil(r.getMaxY()));
    }

    public FontMetrics getFontMetrics() {
        FontMetrics fm = new FontMetrics();
        getFontMetrics(fm);
        return fm;
    }

    public float getFontMetrics(FontMetrics metrics) {
        java.awt.FontMetrics awt = awtMetrics();
        float ascent = -awt.getAscent();
        float descent = awt.getDescent();
        if (metrics != null) {
            metrics.ascent = ascent;
            metrics.top = ascent;
            metrics.descent = descent;
            metrics.bottom = descent;
            metrics.leading = awt.getLeading();
        }
        return descent - ascent + awt.getLeading();
    }

    public FontMetricsInt getFontMetricsInt() {
        java.awt.FontMetrics awt = awtMetrics();
        FontMetricsInt fm = new FontMetricsInt();
        fm.ascent = -awt.getAscent();
        fm.top = fm.ascent;
        fm.descent = awt.getDescent();
        fm.bottom = fm.descent;
        fm.leading = awt.getLeading();
        return fm;
    }

    // ---- 供 Canvas 使用的 Java2D 映射 ----

    Font awtFont() {
        int awtStyle = Font.PLAIN;
        if (typeface.isBold() || fakeBold) awtStyle |= Font.BOLD;
        if (typeface.isItalic()) awtStyle |= Font.ITALIC;
        return new Font(typeface.family(), awtStyle, 1).deriveFont(textSize);
    }

    private java.awt.FontMetrics awtMetrics() {
        BufferedImage scratch = new BufferedImage(1, 1, BufferedImage.TYPE_INT_ARGB);
        java.awt.Graphics2D g = scratch.createGraphics();
        try {
            return g.getFontMetrics(awtFont());
        } finally {
            g.dispose();
        }
    }

    java.awt.Paint awtPaint() {
        java.awt.Paint fromShader = shader == null ? null : shader.toAwtPaint();
        return fromShader != null ? fromShader : new java.awt.Color(color, true);
    }

    BasicStroke awtStroke() {
        int cap = strokeCap == Cap.ROUND ? BasicStroke.CAP_ROUND
                : strokeCap == Cap.SQUARE ? BasicStroke.CAP_SQUARE : BasicStroke.CAP_BUTT;
        int join = strokeJoin == Join.ROUND ? BasicStroke.JOIN_ROUND
                : strokeJoin == Join.BEVEL ? BasicStroke.JOIN_BEVEL : BasicStroke.JOIN_MITER;
        // Android 的 0 宽描边是「发丝线」，即 1 像素
        return new BasicStroke(strokeWidth <= 0 ? 1f : strokeWidth, cap, join);
    }
}
