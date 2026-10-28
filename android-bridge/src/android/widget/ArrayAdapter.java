package android.widget;

import android.content.Context;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;

/**
 * android.widget.ArrayAdapter：以列表为数据源；宿主显示每项的 {@code toString()}。
 */
public class ArrayAdapter<T> extends BaseAdapter {

    private final List<T> objects;

    public ArrayAdapter(Context context, int resource) {
        this.objects = new ArrayList<>();
    }

    public ArrayAdapter(Context context, int resource, int textViewResourceId) {
        this(context, resource);
    }

    public ArrayAdapter(Context context, int resource, T[] objects) {
        this.objects = new ArrayList<>(Arrays.asList(objects));
    }

    public ArrayAdapter(Context context, int resource, int textViewResourceId, T[] objects) {
        this(context, resource, objects);
    }

    public ArrayAdapter(Context context, int resource, List<T> objects) {
        // 与 Android 一致：直接引用调用方的列表，调用方修改后 notifyDataSetChanged 即可生效
        this.objects = objects;
    }

    public ArrayAdapter(Context context, int resource, int textViewResourceId, List<T> objects) {
        this(context, resource, objects);
    }

    public void setDropDownViewResource(int resource) {
    }

    public void add(T object) {
        objects.add(object);
        notifyDataSetChanged();
    }

    public void addAll(Collection<? extends T> collection) {
        objects.addAll(collection);
        notifyDataSetChanged();
    }

    public void clear() {
        objects.clear();
        notifyDataSetChanged();
    }

    @Override
    public int getCount() {
        return objects.size();
    }

    @Override
    public T getItem(int position) {
        return objects.get(position);
    }

    public int getPosition(T item) {
        return objects.indexOf(item);
    }
}
