package android.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.util.AttributeSet;

/**
 * android.widget.Switch：开关。宿主渲染为开关控件。
 */
public class Switch extends CompoundButton {

    public Switch(Context context) {
        super(context);
    }

    public Switch(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public Switch(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void setTextOn(CharSequence textOn) {
    }

    public void setTextOff(CharSequence textOff) {
    }

    public void setShowText(boolean showText) {
    }

    public void setThumbTintList(ColorStateList tint) {
    }

    public void setTrackTintList(ColorStateList tint) {
    }
}
