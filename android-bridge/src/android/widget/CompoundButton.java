package android.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;

/**
 * android.widget.CompoundButton：带选中状态的按钮（开关 / 复选 / 单选的共同父类）。
 *
 * <p>点击语义与 Android 一致：{@link #performClick()} 先切换选中状态（触发
 * {@link OnCheckedChangeListener}），再回调点击监听。
 */
public abstract class CompoundButton extends Button {

    private volatile boolean checked;
    private boolean broadcasting;
    private OnCheckedChangeListener onCheckedChangeListener;

    public CompoundButton(Context context) {
        super(context);
    }

    public CompoundButton(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public CompoundButton(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public boolean isChecked() {
        return checked;
    }

    public void setChecked(boolean checked) {
        if (this.checked == checked) return;
        this.checked = checked;
        notifyChanged();
        // 与 Android 一样防止监听里再次 setChecked 造成递归
        if (broadcasting) return;
        broadcasting = true;
        try {
            if (onCheckedChangeListener != null) onCheckedChangeListener.onCheckedChanged(this, checked);
            onCheckedStateChanged(checked);
        } finally {
            broadcasting = false;
        }
    }

    /** 选中状态变化后的子类钩子（RadioButton 用来通知所属 RadioGroup）。 */
    void onCheckedStateChanged(boolean checked) {
    }

    public void toggle() {
        setChecked(!checked);
    }

    @Override
    public boolean performClick() {
        toggle();
        return super.performClick();
    }

    public void setOnCheckedChangeListener(OnCheckedChangeListener listener) {
        this.onCheckedChangeListener = listener;
    }

    public void setButtonDrawable(Drawable drawable) {
    }

    public void setButtonDrawable(int resId) {
    }

    public void setButtonTintList(ColorStateList tint) {
    }

    public interface OnCheckedChangeListener {
        void onCheckedChanged(CompoundButton buttonView, boolean isChecked);
    }
}
