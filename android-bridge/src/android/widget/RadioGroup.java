package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;

/**
 * android.widget.RadioGroup：互斥单选组。子 RadioButton 没有 id 时与 Android 一样自动分配。
 */
public class RadioGroup extends LinearLayout {

    private int checkedId = -1;
    private boolean updating;
    private OnCheckedChangeListener onCheckedChangeListener;

    public RadioGroup(Context context) {
        super(context);
        setOrientation(VERTICAL);
    }

    public RadioGroup(Context context, AttributeSet attrs) {
        super(context, attrs);
        setOrientation(VERTICAL);
    }

    @Override
    public void addView(View child, int index, ViewGroup.LayoutParams params) {
        if (child instanceof RadioButton) {
            if (child.getId() == 0) child.setId(View.generateViewId());
            if (((RadioButton) child).isChecked()) checkedId = child.getId();
        }
        super.addView(child, index, params);
    }

    public void check(int id) {
        if (id != -1 && id == checkedId) return;
        updating = true;
        try {
            for (int i = 0; i < getChildCount(); i++) {
                View child = getChildAt(i);
                if (child instanceof RadioButton) ((RadioButton) child).setChecked(child.getId() == id);
            }
        } finally {
            updating = false;
        }
        setCheckedId(id);
    }

    public void clearCheck() {
        check(-1);
    }

    public int getCheckedRadioButtonId() {
        return checkedId;
    }

    void onChildChecked(RadioButton child) {
        if (updating) return;
        updating = true;
        try {
            for (int i = 0; i < getChildCount(); i++) {
                View other = getChildAt(i);
                if (other instanceof RadioButton && other != child) ((RadioButton) other).setChecked(false);
            }
        } finally {
            updating = false;
        }
        setCheckedId(child.getId());
    }

    private void setCheckedId(int id) {
        if (checkedId == id) return;
        checkedId = id;
        if (onCheckedChangeListener != null) onCheckedChangeListener.onCheckedChanged(this, id);
    }

    public void setOnCheckedChangeListener(OnCheckedChangeListener listener) {
        this.onCheckedChangeListener = listener;
    }

    public interface OnCheckedChangeListener {
        void onCheckedChanged(RadioGroup group, int checkedId);
    }
}
