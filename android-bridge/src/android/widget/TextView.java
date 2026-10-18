package android.widget;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/**
 * Minimal android.widget.TextView stub。
 */
public class TextView extends View {

    private CharSequence text;

    public TextView(Context context) {
        super(context);
    }

    public void setText(CharSequence text) {
        this.text = text;
    }

    public CharSequence getText() {
        return text;
    }

    public void setTextColor(int color) {
    }

    public void setTextSize(float size) {
    }

    public void setTextSize(int unit, float size) {
    }

    public void setGravity(int gravity) {
    }

    public void setSingleLine() {
    }

    public void setSingleLine(boolean singleLine) {
    }

    public void setMaxLines(int maxLines) {
    }

    public void setEllipsize(Object where) {
    }

    public void setLineSpacing(float add, float mult) {
    }

    public void append(CharSequence text) {
    }
}
