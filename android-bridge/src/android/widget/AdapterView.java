package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;

/**
 * android.widget.AdapterView：按位置选择条目的容器（下拉框的父类）。
 */
public abstract class AdapterView<T extends Adapter> extends ViewGroup {

    public static final int INVALID_POSITION = -1;

    private int selectedPosition = INVALID_POSITION;
    private OnItemSelectedListener onItemSelectedListener;
    private OnItemClickListener onItemClickListener;

    public AdapterView(Context context) {
        super(context);
    }

    public AdapterView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public abstract T getAdapter();

    public abstract void setAdapter(T adapter);

    /** 绑定适配器的公共处理：与 Android 一样，有数据时默认选中第一项。 */
    protected final void onAdapterChanged(T adapter) {
        if (adapter instanceof BaseAdapter) ((BaseAdapter) adapter).bind(this);
        selectedPosition = adapter != null && adapter.getCount() > 0 ? 0 : INVALID_POSITION;
        notifyChanged();
    }

    public int getCount() {
        T adapter = getAdapter();
        return adapter == null ? 0 : adapter.getCount();
    }

    public void setSelection(int position) {
        if (position < 0 || position >= getCount() || position == selectedPosition) return;
        selectedPosition = position;
        notifyChanged();
        if (onItemSelectedListener != null) onItemSelectedListener.onItemSelected(this, null, position, position);
    }

    public int getSelectedItemPosition() {
        return selectedPosition;
    }

    public long getSelectedItemId() {
        return selectedPosition;
    }

    public Object getSelectedItem() {
        T adapter = getAdapter();
        return adapter == null || selectedPosition < 0 ? null : adapter.getItem(selectedPosition);
    }

    public Object getItemAtPosition(int position) {
        T adapter = getAdapter();
        return adapter == null || position < 0 ? null : adapter.getItem(position);
    }

    public void setOnItemSelectedListener(OnItemSelectedListener listener) {
        this.onItemSelectedListener = listener;
    }

    public void setOnItemClickListener(OnItemClickListener listener) {
        this.onItemClickListener = listener;
    }

    public boolean performItemClick(View view, int position, long id) {
        if (onItemClickListener == null) return false;
        onItemClickListener.onItemClick(this, view, position, id);
        return true;
    }

    public interface OnItemSelectedListener {
        void onItemSelected(AdapterView<?> parent, View view, int position, long id);

        void onNothingSelected(AdapterView<?> parent);
    }

    public interface OnItemClickListener {
        void onItemClick(AdapterView<?> parent, View view, int position, long id);
    }
}
