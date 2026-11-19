package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/** 网格列表的桌面适配层；保存数据适配器和布局参数，不模拟屏幕测量。 */
public class GridView extends AbsListView {
    private int numColumns = 1;
    private int horizontalSpacing;
    private int verticalSpacing;

    public GridView(Context context) {
        super(context);
    }

    public GridView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    @Override
    public ListAdapter getAdapter() {
        return super.getAdapter();
    }

    @Override
    public void setAdapter(ListAdapter adapter) {
        super.setAdapter(adapter);
    }

    public void setNumColumns(int numColumns) {
        this.numColumns = numColumns;
    }

    public int getNumColumns() {
        return numColumns;
    }

    public void setHorizontalSpacing(int spacing) {
        horizontalSpacing = spacing;
    }

    public int getHorizontalSpacing() {
        return horizontalSpacing;
    }

    public void setVerticalSpacing(int spacing) {
        verticalSpacing = spacing;
    }

    public int getVerticalSpacing() {
        return verticalSpacing;
    }
}
