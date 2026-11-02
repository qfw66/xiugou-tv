package android.text;

import android.graphics.Paint;

/**
 * android.text.TextPaint：TextView 的画笔，语义上就是 {@link Paint} 多了些文字排版状态。
 *
 * <p>aowu 载荷里几个站点（Hgdh / Hggg 等）会走 `TextView.getPaint()` 做文字测量（HTML 转纯文本
 * 排版时算换行点），主类缺失会让整站以 {@code ClassNotFoundException: android.text.TextPaint}
 * 挂掉，所以这里给一个最小实现；{@link Paint} 已经是 Java2D 语义，测量能力直接继承。
 */
public class TextPaint extends Paint {

    /** 与 android.text.TextPaint 一致的公开字段（载荷可能直接读）。 */
    public int bgColor;
    public int baselineShift;
    public int linkColor;
    public float density = 1f;
    public float underlineThickness;
    public boolean drawableStateChanged = true;

    public TextPaint() {
        super();
    }

    public TextPaint(int flags) {
        super(flags);
    }

    public TextPaint(Paint p) {
        super(p);
    }

    /** 复制一份同样状态的画笔（载荷排版时会 fork 出测量用的副本）。 */
    public void set(TextPaint tp) {
        super.set(tp);
        this.bgColor = tp.bgColor;
        this.baselineShift = tp.baselineShift;
        this.linkColor = tp.linkColor;
        this.density = tp.density;
        this.underlineThickness = tp.underlineThickness;
    }
}
