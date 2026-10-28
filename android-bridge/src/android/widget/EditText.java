package android.widget;

import android.content.Context;
import android.text.Editable;
import android.text.SpannableStringBuilder;
import android.util.AttributeSet;

/**
 * android.widget.EditText 的桌面实现：内容保存在 {@link Editable} 里，
 * 由宿主（Flutter 输入框）回填用户输入，再由载荷在按钮回调里 {@code getText().toString()} 读取。
 */
public class EditText extends TextView {

    private final SpannableStringBuilder editable = new SpannableStringBuilder();

    public EditText(Context context) {
        super(context);
        init();
    }

    public EditText(Context context, AttributeSet attrs) {
        super(context, attrs);
        init();
    }

    public EditText(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init();
    }

    private void init() {
        // 载荷直接改写 getText() 返回的对象（insert / delete / clear）时也要让宿主刷新
        editable.setOnChangeListener(source -> notifyChanged());
    }

    @Override
    public Editable getText() {
        return editable;
    }

    @Override
    public void setText(CharSequence text) {
        // 父类构造期间 editable 还没初始化
        if (editable == null) return;
        String old = editable.toString();
        editable.setQuietly(text);
        fireWatchers(old, editable);
        notifyChanged();
    }

    /**
     * 宿主回填用户在 Flutter 输入框里的内容（桌面扩展，不是 Android API）：
     * 触发 TextWatcher，但不回推变更通知，避免与用户输入互相覆盖。
     */
    public void applyUserInput(String value) {
        String old = editable.toString();
        if (old.equals(value == null ? "" : value)) return;
        editable.setQuietly(value);
        fireWatchers(old, editable);
    }

    /** 兼容旧调用：取当前文字。 */
    public String getTextString() {
        return editable.toString();
    }

    public void setSelection(int index) {
    }

    public void setSelection(int start, int stop) {
    }

    public void selectAll() {
    }

    public void setCursorVisible(boolean visible) {
    }
}
