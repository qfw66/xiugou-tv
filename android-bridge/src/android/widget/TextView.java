package android.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.text.Editable;
import android.text.Layout;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.text.method.MovementMethod;
import android.util.AttributeSet;
import android.view.KeyEvent;
import android.view.View;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * android.widget.TextView 的桌面实现：保存文字、提示、输入类型等宿主需要呈现的状态，不做排版。
 */
public class TextView extends View {

    private volatile CharSequence text = "";
    private volatile CharSequence hint;
    private int inputType = 0x00000001;
    private int textColor = 0xFF000000;
    private float textSize = 14f;
    private int gravity;
    private int maxLines = Integer.MAX_VALUE;
    private int minHeight;
    private int minWidth;
    private boolean includeFontPadding = true;
    private Typeface typeface = Typeface.DEFAULT;
    private OnEditorActionListener editorActionListener;
    private final List<TextWatcher> watchers = new CopyOnWriteArrayList<>();

    public TextView(Context context) {
        super(context);
    }

    public TextView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public TextView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    // ---- 文字 ----

    public void setText(CharSequence text) {
        CharSequence value = text == null ? "" : text;
        CharSequence old = this.text;
        this.text = value;
        fireWatchers(old, value);
        notifyChanged();
    }

    public final void setText(int resId) {
        setText(getContext().getResources().getString(resId));
    }

    public CharSequence getText() {
        return text;
    }

    public void append(CharSequence more) {
        if (more != null) setText(getText().toString() + more);
    }

    public int length() {
        return getText().length();
    }

    public void setHint(CharSequence hint) {
        this.hint = hint;
        notifyChanged();
    }

    public void setHint(int resId) {
        setHint(getContext().getResources().getString(resId));
    }

    public CharSequence getHint() {
        return hint;
    }

    public void setInputType(int type) {
        this.inputType = type;
        notifyChanged();
    }

    public int getInputType() {
        return inputType;
    }

    /** 输入类型是否为密码（桌面扩展：宿主据此遮挡输入）。 */
    public boolean isPasswordInput() {
        int cls = inputType & 0x0000000f;
        int variation = inputType & 0x00000ff0;
        return (cls == 0x00000001 && (variation == 0x00000080 || variation == 0x000000e0))
                || (cls == 0x00000002 && variation == 0x00000010);
    }

    public void setSingleLine() {
        setSingleLine(true);
    }

    public void setSingleLine(boolean singleLine) {
        if (singleLine) maxLines = 1;
    }

    public void setLines(int lines) {
        maxLines = lines;
    }

    public void setMaxLines(int maxLines) {
        this.maxLines = maxLines;
    }

    public int getMaxLines() {
        return maxLines;
    }

    public void setMinLines(int minLines) {
    }

    // ---- 监听 ----

    public void addTextChangedListener(TextWatcher watcher) {
        if (watcher != null) watchers.add(watcher);
    }

    public void removeTextChangedListener(TextWatcher watcher) {
        watchers.remove(watcher);
    }

    /** 当前注册的 TextWatcher（供子类回调）。 */
    protected final List<TextWatcher> watchers() {
        return watchers;
    }

    protected void fireWatchers(CharSequence old, CharSequence value) {
        if (watchers.isEmpty() || old.toString().contentEquals(value)) return;
        for (TextWatcher w : watchers) w.beforeTextChanged(old, 0, old.length(), value.length());
        for (TextWatcher w : watchers) w.onTextChanged(value, 0, old.length(), value.length());
        Editable editable = value instanceof Editable ? (Editable) value
                : Editable.Factory.getInstance().newEditable(value);
        for (TextWatcher w : watchers) w.afterTextChanged(editable);
    }

    public void setOnEditorActionListener(OnEditorActionListener l) {
        this.editorActionListener = l;
    }

    /** 宿主在用户按回车时调用（桌面扩展）。 */
    public boolean dispatchEditorAction(int actionId) {
        OnEditorActionListener l = editorActionListener;
        return l != null && l.onEditorAction(this, actionId, null);
    }

    public interface OnEditorActionListener {
        boolean onEditorAction(TextView v, int actionId, KeyEvent event);
    }

    // ---- 外观（桌面端只保存，粗体会传给宿主） ----

    public void setTextColor(int color) {
        this.textColor = color;
    }

    public void setTextColor(ColorStateList colors) {
        if (colors != null) this.textColor = colors.getDefaultColor();
    }

    public int getCurrentTextColor() {
        return textColor;
    }

    public ColorStateList getTextColors() {
        return ColorStateList.valueOf(textColor);
    }

    public void setHintTextColor(int color) {
    }

    public void setTextSize(float size) {
        this.textSize = size;
    }

    public void setTextSize(int unit, float size) {
        this.textSize = size;
    }

    public float getTextSize() {
        return textSize;
    }

    public void setTypeface(Typeface tf) {
        this.typeface = tf == null ? Typeface.DEFAULT : tf;
        notifyChanged();
    }

    public void setTypeface(Typeface tf, int style) {
        setTypeface(Typeface.create(tf, style));
    }

    public Typeface getTypeface() {
        return typeface;
    }

    /** 是否粗体（桌面扩展）。 */
    public boolean isBold() {
        return typeface != null && typeface.isBold();
    }

    public void setGravity(int gravity) {
        this.gravity = gravity;
    }

    public int getGravity() {
        return gravity;
    }

    public void setEllipsize(TextUtils.TruncateAt where) {
    }

    public void setLineSpacing(float add, float mult) {
    }

    public void setIncludeFontPadding(boolean includepad) {
        this.includeFontPadding = includepad;
    }

    public boolean getIncludeFontPadding() {
        return includeFontPadding;
    }

    public void setMinHeight(int minPixels) {
        this.minHeight = minPixels;
    }

    public int getMinHeight() {
        return minHeight;
    }

    public void setMinWidth(int minPixels) {
        this.minWidth = minPixels;
    }

    public int getMinWidth() {
        return minWidth;
    }

    public void setMaxWidth(int maxPixels) {
    }

    public void setMaxEms(int maxEms) {
    }

    public void setHorizontallyScrolling(boolean whether) {
    }

    public void setImeOptions(int imeOptions) {
    }

    public void setSelectAllOnFocus(boolean selectAllOnFocus) {
    }

    public void setTextIsSelectable(boolean selectable) {
    }

    public void setMovementMethod(MovementMethod movement) {
    }

    public void setCompoundDrawables(android.graphics.drawable.Drawable left, android.graphics.drawable.Drawable top,
                                     android.graphics.drawable.Drawable right, android.graphics.drawable.Drawable bottom) {
    }

    public int getSelectionStart() {
        return getText().length();
    }

    public int getSelectionEnd() {
        return getText().length();
    }

    public Layout getLayout() {
        return null;
    }

    protected void onSelectionChanged(int selStart, int selEnd) {
    }
}
