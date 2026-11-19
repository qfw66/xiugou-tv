package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.ViewGroup;

/** 基础列表容器契约；桌面端仅保留载荷创建布局参数所需的类型。 */
public abstract class AbsListView extends AdapterView<ListAdapter> {
    private ListAdapter adapter;

    protected AbsListView(Context context) {
        super(context);
    }

    protected AbsListView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    @Override
    public ListAdapter getAdapter() {
        return adapter;
    }

    @Override
    public void setAdapter(ListAdapter adapter) {
        this.adapter = adapter;
        onAdapterChanged(adapter);
    }

    public static class LayoutParams extends ViewGroup.LayoutParams {
        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(ViewGroup.LayoutParams source) {
            super(source);
        }
    }
}
