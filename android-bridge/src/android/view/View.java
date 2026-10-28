package android.view;

import android.app.DialogHost;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * android.view.View 的桌面实现：只保存状态，不测量、不绘制。
 *
 * <p>弹窗会被宿主序列化成结构快照交给 Flutter 渲染，所以影响呈现的状态（文字、可见性、子控件、
 * 点击监听等）必须如实保存，并在变化时通过 {@link #notifyChanged()} 通知宿主；
 * 与呈现无关的几何 / 样式方法保持空实现，只为让载荷不因缺方法而崩溃。
 */
public class View {

    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;

    public static final int FOCUS_DOWN = 130;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_AUTO = 0;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_YES = 1;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_NO = 2;

    private static final AtomicInteger NEXT_GENERATED_ID = new AtomicInteger(1);
    /** 宿主侧的稳定标识，与载荷可见的 {@link #getId()} 无关。 */
    private static final AtomicInteger NEXT_HOST_ID = new AtomicInteger(1);

    private final Context context;
    private final int hostId = NEXT_HOST_ID.getAndIncrement();
    private ViewParent parent;
    private ViewGroup.LayoutParams layoutParams;
    private volatile int visibility = VISIBLE;
    private volatile boolean enabled = true;
    private boolean clickable;
    private boolean selected;
    private boolean focused;
    private boolean attached;
    private Object tag;
    private Map<Integer, Object> keyedTags;
    private int id;
    private int paddingLeft;
    private int paddingTop;
    private int paddingRight;
    private int paddingBottom;
    private int minimumWidth;
    private int minimumHeight;
    private float x;
    private float y;
    private Drawable background;
    private volatile OnClickListener onClickListener;
    private ViewTreeObserver viewTreeObserver;
    private final CopyOnWriteArrayList<OnAttachStateChangeListener> attachListeners = new CopyOnWriteArrayList<>();

    public View(Context context) {
        this.context = context;
    }

    public View(Context context, AttributeSet attrs) {
        this(context);
    }

    public View(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context);
    }

    public static int generateViewId() {
        return NEXT_GENERATED_ID.getAndIncrement();
    }

    /** 宿主用的控件标识（桌面扩展，不是 Android API）。 */
    public final int getHostId() {
        return hostId;
    }

    /** 通知宿主：本控件的呈现内容变了（桌面扩展，不是 Android API）。 */
    protected final void notifyChanged() {
        DialogHost.get().onChanged(this);
    }

    public Context getContext() {
        return context != null ? context : Context.get();
    }

    public android.content.res.Resources getResources() {
        return getContext().getResources();
    }

    // ---- 树结构 ----

    public ViewParent getParent() {
        return parent;
    }

    /** 由 {@link ViewGroup} 维护（桌面扩展，不是 Android API）。 */
    final void assignParent(ViewParent parent) {
        this.parent = parent;
    }

    public View getRootView() {
        View root = this;
        while (root.parent instanceof View) {
            root = (View) root.parent;
        }
        return root;
    }

    public View findViewById(int id) {
        return id != 0 && this.id == id ? this : null;
    }

    public View findViewWithTag(Object tag) {
        return tag != null && tag.equals(this.tag) ? this : null;
    }

    public void bringToFront() {
    }

    // ---- 状态 ----

    public void setVisibility(int visibility) {
        if (this.visibility != visibility) {
            this.visibility = visibility;
            notifyChanged();
        }
    }

    public int getVisibility() {
        return visibility;
    }

    public boolean isShown() {
        return visibility == VISIBLE;
    }

    public void setEnabled(boolean enabled) {
        if (this.enabled != enabled) {
            this.enabled = enabled;
            notifyChanged();
        }
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setClickable(boolean clickable) {
        this.clickable = clickable;
    }

    public boolean isClickable() {
        return clickable || onClickListener != null;
    }

    public void setSelected(boolean selected) {
        this.selected = selected;
    }

    public boolean isSelected() {
        return selected;
    }

    public void setActivated(boolean activated) {
    }

    public void setFocusable(boolean focusable) {
    }

    public void setFocusableInTouchMode(boolean focusableInTouchMode) {
    }

    public boolean requestFocus() {
        focused = true;
        return true;
    }

    public boolean requestFocus(int direction) {
        return requestFocus();
    }

    public boolean isFocused() {
        return focused;
    }

    public void setTag(Object tag) {
        this.tag = tag;
    }

    public Object getTag() {
        return tag;
    }

    public void setTag(int key, Object tag) {
        if (keyedTags == null) keyedTags = new HashMap<>();
        keyedTags.put(key, tag);
    }

    public Object getTag(int key) {
        return keyedTags == null ? null : keyedTags.get(key);
    }

    public void setId(int id) {
        this.id = id;
    }

    public int getId() {
        return id;
    }

    // ---- 事件 ----

    public void setOnClickListener(OnClickListener l) {
        this.onClickListener = l;
        notifyChanged();
    }

    /** 当前点击监听（桌面扩展，宿主据此判断控件是否可点）。 */
    public OnClickListener getOnClickListener() {
        return onClickListener;
    }

    public boolean performClick() {
        OnClickListener l = onClickListener;
        if (l == null) return false;
        l.onClick(this);
        return true;
    }

    public void setOnLongClickListener(OnLongClickListener l) {
    }

    public void setOnTouchListener(OnTouchListener l) {
    }

    public void setOnKeyListener(OnKeyListener l) {
    }

    public void setOnFocusChangeListener(OnFocusChangeListener l) {
    }

    public boolean post(Runnable action) {
        DialogHost.get().post(action);
        return true;
    }

    public boolean postDelayed(Runnable action, long delayMillis) {
        return post(action);
    }

    public void addOnAttachStateChangeListener(OnAttachStateChangeListener listener) {
        if (listener != null) attachListeners.add(listener);
    }

    public void removeOnAttachStateChangeListener(OnAttachStateChangeListener listener) {
        attachListeners.remove(listener);
    }

    public boolean isAttachedToWindow() {
        return attached;
    }

    /**
     * 弹窗显示 / 关闭时由宿主调用（桌面扩展，不是 Android API）：
     * 回调 {@link #onAttachedToWindow()} / {@link #onDetachedFromWindow()} 与 attach 监听。
     */
    public void dispatchAttached(boolean attached) {
        if (this.attached == attached) return;
        this.attached = attached;
        if (attached) {
            onAttachedToWindow();
            for (OnAttachStateChangeListener l : attachListeners) l.onViewAttachedToWindow(this);
        } else {
            onDetachedFromWindow();
            for (OnAttachStateChangeListener l : attachListeners) l.onViewDetachedFromWindow(this);
        }
    }

    protected void onAttachedToWindow() {
    }

    protected void onDetachedFromWindow() {
    }

    protected void onDraw(Canvas canvas) {
    }

    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
    }

    protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
    }

    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
    }

    protected void onScrollChanged(int l, int t, int oldl, int oldt) {
    }

    // ---- 布局与外观（桌面端不参与呈现） ----

    public void setLayoutParams(ViewGroup.LayoutParams params) {
        this.layoutParams = params;
    }

    public ViewGroup.LayoutParams getLayoutParams() {
        return layoutParams;
    }

    public void setBackgroundColor(int color) {
    }

    public void setBackground(Drawable background) {
        this.background = background;
    }

    public void setBackgroundDrawable(Drawable background) {
        this.background = background;
    }

    public Drawable getBackground() {
        return background;
    }

    public void setBackgroundResource(int resId) {
    }

    public void setBackgroundTintList(android.content.res.ColorStateList tint) {
    }

    public void setPadding(int left, int top, int right, int bottom) {
        this.paddingLeft = left;
        this.paddingTop = top;
        this.paddingRight = right;
        this.paddingBottom = bottom;
    }

    public int getPaddingLeft() {
        return paddingLeft;
    }

    public int getPaddingTop() {
        return paddingTop;
    }

    public int getPaddingRight() {
        return paddingRight;
    }

    public int getPaddingBottom() {
        return paddingBottom;
    }

    public void setMinimumWidth(int minWidth) {
        this.minimumWidth = minWidth;
    }

    public void setMinimumHeight(int minHeight) {
        this.minimumHeight = minHeight;
    }

    public void setElevation(float elevation) {
    }

    public void setScaleX(float scaleX) {
    }

    public void setScaleY(float scaleY) {
    }

    public void setAlpha(float alpha) {
    }

    public void setX(float x) {
        this.x = x;
    }

    public void setY(float y) {
        this.y = y;
    }

    public float getX() {
        return x;
    }

    public float getY() {
        return y;
    }

    public int getTop() {
        return 0;
    }

    public int getLeft() {
        return 0;
    }

    public int getScrollX() {
        return 0;
    }

    public int getScrollY() {
        return 0;
    }

    public void scrollTo(int x, int y) {
    }

    public int getWidth() {
        return 0;
    }

    public int getHeight() {
        return 0;
    }

    public int getMeasuredWidth() {
        return minimumWidth;
    }

    public int getMeasuredHeight() {
        return minimumHeight;
    }

    public void measure(int widthMeasureSpec, int heightMeasureSpec) {
    }

    protected final void setMeasuredDimension(int measuredWidth, int measuredHeight) {
    }

    public void layout(int l, int t, int r, int b) {
    }

    public void setHorizontalScrollBarEnabled(boolean enabled) {
    }

    public void setVerticalScrollBarEnabled(boolean enabled) {
    }

    public void setImportantForAccessibility(int mode) {
    }

    public void getLocationOnScreen(int[] outLocation) {
        if (outLocation != null && outLocation.length >= 2) {
            outLocation[0] = 0;
            outLocation[1] = 0;
        }
    }

    public void getLocationInWindow(int[] outLocation) {
        getLocationOnScreen(outLocation);
    }

    public boolean getGlobalVisibleRect(Rect r) {
        if (r != null) r.set(0, 0, getWidth(), getHeight());
        return isShown();
    }

    public void getWindowVisibleDisplayFrame(Rect outRect) {
        if (outRect != null) outRect.set(0, 0, 1920, 1080);
    }

    public android.os.IBinder getWindowToken() {
        return null;
    }

    public ViewTreeObserver getViewTreeObserver() {
        if (viewTreeObserver == null) viewTreeObserver = new ViewTreeObserver();
        return viewTreeObserver;
    }

    public void requestLayout() {
    }

    public void invalidate() {
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

    public interface OnAttachStateChangeListener {
        void onViewAttachedToWindow(View v);

        void onViewDetachedFromWindow(View v);
    }

    public static class MeasureSpec {
        public static final int UNSPECIFIED = 0;
        public static final int EXACTLY = 1 << 30;
        public static final int AT_MOST = 2 << 30;
        private static final int MODE_MASK = 3 << 30;

        public static int makeMeasureSpec(int size, int mode) {
            return (size & ~MODE_MASK) | (mode & MODE_MASK);
        }

        public static int getMode(int measureSpec) {
            return measureSpec & MODE_MASK;
        }

        public static int getSize(int measureSpec) {
            return measureSpec & ~MODE_MASK;
        }
    }
}
