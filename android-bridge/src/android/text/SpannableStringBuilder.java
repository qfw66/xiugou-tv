package android.text;

/**
 * android.text.SpannableStringBuilder：{@link Editable} 的默认实现（桌面端不支持 span，只保存文字）。
 *
 * <p>{@link #setOnChangeListener} 是桌面扩展：EditText 借它在载荷改写内容时通知宿主与 TextWatcher。
 */
public class SpannableStringBuilder implements Editable {

    /** 内容变化回调（桌面扩展）。 */
    public interface OnChangeListener {
        void onChanged(SpannableStringBuilder source);
    }

    private final StringBuilder text;
    private OnChangeListener listener;

    public SpannableStringBuilder() {
        this("");
    }

    public SpannableStringBuilder(CharSequence text) {
        this.text = new StringBuilder(text == null ? "" : text);
    }

    public void setOnChangeListener(OnChangeListener listener) {
        this.listener = listener;
    }

    /** 整体替换内容，不触发回调（宿主回填用户输入时使用）。 */
    public void setQuietly(CharSequence value) {
        text.setLength(0);
        if (value != null) text.append(value);
    }

    private SpannableStringBuilder changed() {
        if (listener != null) listener.onChanged(this);
        return this;
    }

    @Override
    public Editable replace(int st, int en, CharSequence tb) {
        text.replace(st, en, tb == null ? "" : tb.toString());
        return changed();
    }

    @Override
    public Editable insert(int where, CharSequence tb) {
        text.insert(where, tb == null ? "" : tb);
        return changed();
    }

    @Override
    public Editable delete(int st, int en) {
        text.delete(st, en);
        return changed();
    }

    @Override
    public Editable append(CharSequence tb) {
        text.append(tb);
        return changed();
    }

    @Override
    public Editable append(CharSequence tb, int start, int end) {
        text.append(tb, start, end);
        return changed();
    }

    @Override
    public Editable append(char ch) {
        text.append(ch);
        return changed();
    }

    @Override
    public void clear() {
        text.setLength(0);
        changed();
    }

    @Override
    public int length() {
        return text.length();
    }

    @Override
    public char charAt(int index) {
        return text.charAt(index);
    }

    @Override
    public CharSequence subSequence(int start, int end) {
        return text.subSequence(start, end);
    }

    @Override
    public String toString() {
        return text.toString();
    }
}
