package android.view;

import android.content.Context;

/**
 * Minimal android.view.View stub。
 */
public class View {

    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;

    private final Context context;
    private ViewGroup.LayoutParams layoutParams;
    private int visibility = VISIBLE;
    private Object tag;
    private int id;

    public View(Context context) {
        this.context = context;
    }

    public Context getContext() {
        return context != null ? context : Context.get();
    }

    public void setVisibility(int visibility) {
        this.visibility = visibility;
    }

    public int getVisibility() {
        return visibility;
    }

    public void setOnClickListener(OnClickListener l) {
    }

    public void setOnLongClickListener(OnLongClickListener l) {
    }

    public void setOnTouchListener(OnTouchListener l) {
    }

    public void setOnKeyListener(OnKeyListener l) {
    }

    public void setOnFocusChangeListener(OnFocusChangeListener l) {
    }

    public void setLayoutParams(ViewGroup.LayoutParams params) {
        this.layoutParams = params;
    }

    public ViewGroup.LayoutParams getLayoutParams() {
        return layoutParams;
    }

    public void setBackgroundColor(int color) {
    }

    public void setBackground(android.graphics.drawable.Drawable background) {
    }

    public void setPadding(int left, int top, int right, int bottom) {
    }

    public void setTag(Object tag) {
        this.tag = tag;
    }

    public Object getTag() {
        return tag;
    }

    public void setId(int id) {
        this.id = id;
    }

    public int getId() {
        return id;
    }

    public void setClickable(boolean clickable) {
    }

    public void setEnabled(boolean enabled) {
    }

    public boolean isShown() {
        return visibility == VISIBLE;
    }

    public void setFocusable(boolean focusable) {
    }

    public void setSelected(boolean selected) {
    }

    public int getWidth() {
        return 0;
    }

    public int getHeight() {
        return 0;
    }

    public void requestLayout() {
    }

    public void invalidate() {
    }

    public View findViewById(int id) {
        return null;
    }

    public interface OnClickListener {
        void onClick(View v);
    }

    public interface OnLongClickListener {
        boolean onLongClick(View v);
    }

    public interface OnTouchListener {
        boolean onTouch(View v, MotionEvent event);
    }

    public interface OnKeyListener {
        boolean onKey(View v, int keyCode, KeyEvent event);
    }

    public interface OnFocusChangeListener {
        void onFocusChange(View v, boolean hasFocus);
    }
}
