package android.widget;

import android.content.Context;

/**
 * Minimal android.widget.EditText stub。
 */
public class EditText extends TextView {

    private String value = "";

    public EditText(Context context) {
        super(context);
    }

    public void setText(CharSequence text) {
        this.value = text == null ? "" : text.toString();
    }

    public String getTextString() {
        return value;
    }

    public void setHint(CharSequence hint) {
    }

    public void setHint(int resId) {
    }
}
