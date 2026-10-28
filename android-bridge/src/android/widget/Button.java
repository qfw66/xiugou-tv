package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * android.widget.Button：可点击的文字控件，宿主渲染成按钮。
 */
public class Button extends TextView {

    public Button(Context context) {
        super(context);
    }

    public Button(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public Button(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }
}
