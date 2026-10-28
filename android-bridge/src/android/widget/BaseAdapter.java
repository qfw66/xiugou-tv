package android.widget;

import android.app.DialogHost;

/**
 * android.widget.BaseAdapter：数据变化时通知宿主刷新正在显示的下拉框。
 */
public abstract class BaseAdapter implements SpinnerAdapter {

    private AdapterView<?> owner;

    /** 由 {@link AdapterView#setAdapter} 绑定（桌面扩展）。 */
    void bind(AdapterView<?> owner) {
        this.owner = owner;
    }

    public void notifyDataSetChanged() {
        if (owner != null) DialogHost.get().onChanged(owner);
    }

    public void notifyDataSetInvalidated() {
        notifyDataSetChanged();
    }

    @Override
    public long getItemId(int position) {
        return position;
    }
}
