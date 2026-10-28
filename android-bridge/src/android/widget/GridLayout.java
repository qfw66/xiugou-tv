package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.ViewGroup;

/**
 * android.widget.GridLayout：宿主按列数把子控件排成网格（不支持跨行跨列，按添加顺序填充）。
 */
public class GridLayout extends ViewGroup {

    public static final int HORIZONTAL = LinearLayout.HORIZONTAL;
    public static final int VERTICAL = LinearLayout.VERTICAL;
    public static final int ALIGN_BOUNDS = 0;
    public static final int ALIGN_MARGINS = 1;
    public static final int UNDEFINED = Integer.MIN_VALUE;

    private int columnCount = UNDEFINED;
    private int rowCount = UNDEFINED;
    private int orientation = HORIZONTAL;

    public GridLayout(Context context) {
        super(context);
    }

    public GridLayout(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public GridLayout(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void setColumnCount(int columnCount) {
        this.columnCount = columnCount;
        notifyChanged();
    }

    public int getColumnCount() {
        return columnCount;
    }

    public void setRowCount(int rowCount) {
        this.rowCount = rowCount;
    }

    public int getRowCount() {
        return rowCount;
    }

    public void setOrientation(int orientation) {
        this.orientation = orientation;
    }

    public int getOrientation() {
        return orientation;
    }

    public void setUseDefaultMargins(boolean useDefaultMargins) {
    }

    public void setAlignmentMode(int alignmentMode) {
    }

    public void setRowOrderPreserved(boolean rowOrderPreserved) {
    }

    public void setColumnOrderPreserved(boolean columnOrderPreserved) {
    }

    public static Spec spec(int start) {
        return new Spec(start, 1, 0f);
    }

    public static Spec spec(int start, int size) {
        return new Spec(start, size, 0f);
    }

    public static Spec spec(int start, float weight) {
        return new Spec(start, 1, weight);
    }

    public static Spec spec(int start, int size, float weight) {
        return new Spec(start, size, weight);
    }

    public static class Spec {
        final int start;
        final int size;
        final float weight;

        Spec(int start, int size, float weight) {
            this.start = start;
            this.size = size;
            this.weight = weight;
        }
    }

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public Spec rowSpec = spec(UNDEFINED);
        public Spec columnSpec = spec(UNDEFINED);

        public LayoutParams() {
            super(WRAP_CONTENT, WRAP_CONTENT);
        }

        public LayoutParams(Spec rowSpec, Spec columnSpec) {
            this();
            this.rowSpec = rowSpec;
            this.columnSpec = columnSpec;
        }

        public LayoutParams(ViewGroup.LayoutParams params) {
            super(params);
        }

        public void setGravity(int gravity) {
        }
    }
}
