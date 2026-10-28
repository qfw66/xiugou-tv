package android.widget;

import android.view.View;
import android.view.ViewGroup;

/**
 * android.widget.Adapter：列表数据源。宿主只用条目文字（{@code getItem(i).toString()}），不调用 getView。
 */
public interface Adapter {

    int getCount();

    Object getItem(int position);

    long getItemId(int position);

    default View getView(int position, View convertView, ViewGroup parent) {
        return null;
    }

    default boolean isEmpty() {
        return getCount() == 0;
    }
}
