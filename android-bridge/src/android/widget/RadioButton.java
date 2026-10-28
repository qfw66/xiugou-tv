package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * android.widget.RadioButton：单选项。与 Android 一致，点击只能选中、不能取消；
 * 选中后通知所属 {@link RadioGroup} 取消其他项。
 */
public class RadioButton extends CompoundButton {

    public RadioButton(Context context) {
        super(context);
    }

    public RadioButton(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public RadioButton(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    @Override
    public void toggle() {
        if (!isChecked()) super.toggle();
    }

    @Override
    void onCheckedStateChanged(boolean checked) {
        if (checked && getParent() instanceof RadioGroup) ((RadioGroup) getParent()).onChildChecked(this);
    }
}
