package android.text;

/**
 * android.text.Editable：可编辑文本。载荷几乎只用 {@code getText().toString()}，另有少量 insert / delete。
 */
public interface Editable extends CharSequence, Appendable {

    Editable replace(int st, int en, CharSequence text);

    Editable insert(int where, CharSequence text);

    Editable delete(int st, int en);

    @Override
    Editable append(CharSequence text);

    @Override
    Editable append(CharSequence text, int start, int end);

    @Override
    Editable append(char text);

    void clear();

    class Factory {
        private static final Factory INSTANCE = new Factory();

        public static Factory getInstance() {
            return INSTANCE;
        }

        public Editable newEditable(CharSequence source) {
            return new SpannableStringBuilder(source);
        }
    }
}
