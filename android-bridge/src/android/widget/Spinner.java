package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * android.widget.Spinner：下拉选择框，宿主渲染为下拉菜单。
 */
public class Spinner extends AdapterView<SpinnerAdapter> {

    private SpinnerAdapter adapter;

    public Spinner(Context context) {
        super(context);
    }

    public Spinner(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public Spinner(Context context, int mode) {
        super(context);
    }

    @Override
    public SpinnerAdapter getAdapter() {
        return adapter;
    }

    @Override
    public void setAdapter(SpinnerAdapter adapter) {
        this.adapter = adapter;
        onAdapterChanged(adapter);
    }

    public void setPrompt(CharSequence prompt) {
    }
}
