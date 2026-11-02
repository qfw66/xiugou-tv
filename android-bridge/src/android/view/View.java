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

    public static final int FOCUS_BACKWARD = 1;
    public static final int FOCUS_FORWARD = 2;
    public static final int FOCUS_LEFT = 17;
    public static final int FOCUS_UP = 33;
    public static final int FOCUS_RIGHT = 66;
    public static final int FOCUS_DOWN = 130;
    public static final int FOCUSABLES_ALL = 0;
    public static final int FOCUSABLES_TOUCH_MODE = 1;
    public static final int NO_ID = -1;
    public static final int OVER_SCROLL_ALWAYS = 0;
    public static final int OVER_SCROLL_IF_CONTENT_SCROLLS = 1;
    public static final int OVER_SCROLL_NEVER = 2;
    public static final int LAYER_TYPE_NONE = 0;
    public static final int LAYER_TYPE_SOFTWARE = 1;
    public static final int LAYER_TYPE_HARDWARE = 2;
    public static final int SYSTEM_UI_FLAG_VISIBLE = 0;
    public static final int SYSTEM_UI_FLAG_LOW_PROFILE = 0x00000001;
    public static final int SYSTEM_UI_FLAG_HIDE_NAVIGATION = 0x00000002;
    public static final int SYSTEM_UI_FLAG_FULLSCREEN = 0x00000004;
    public static final int SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR = 0x00000010;
    public static final int SYSTEM_UI_FLAG_LAYOUT_STABLE = 0x00000100;
    public static final int SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION = 0x00000200;
    public static final int SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN = 0x00000400;
    public static final int SYSTEM_UI_FLAG_IMMERSIVE = 0x00000800;
    public static final int SYSTEM_UI_FLAG_IMMERSIVE_STICKY = 0x00001000;
    public static final int SYSTEM_UI_FLAG_LIGHT_STATUS_BAR = 0x00002000;
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
    private boolean focusable;
    private boolean focusableInTouchMode;
    private boolean longClickable;
    private CharSequence contentDescription;
    private int nextFocusLeftId = NO_ID;
    private int nextFocusUpId = NO_ID;
    private int nextFocusRightId = NO_ID;
    private int nextFocusDownId = NO_ID;
    private int overScrollMode = OVER_SCROLL_IF_CONTENT_SCROLLS;
    private int layerType = LAYER_TYPE_NONE;
    private int systemUiVisibility;
    private boolean fitsSystemWindows;
    private boolean clipToOutline;
    private float alpha = 1f;
    private float scaleX = 1f;
    private float scaleY = 1f;
    private float translationX;
    private float translationY;
    private float translationZ;
    private float rotation;
    private float rotationX;
    private float rotationY;
    private float pivotX;
    private float pivotY;
    private ViewPropertyAnimator animator;
    private volatile OnLongClickListener onLongClickListener;
    private volatile OnFocusChangeListener onFocusChangeListener;
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
        this.focusable = focusable;
        if (!focusable) this.focusableInTouchMode = false;
    }

    public boolean isFocusable() {
        return focusable;
    }

    public void setFocusableInTouchMode(boolean focusableInTouchMode) {
        this.focusableInTouchMode = focusableInTouchMode;
        if (focusableInTouchMode) this.focusable = true;
    }

    public boolean isFocusableInTouchMode() {
        return focusableInTouchMode;
    }

    /** 电视遥控器操作，始终不是触摸模式。 */
    public boolean isInTouchMode() {
        return false;
    }

    /**
     * 桌面端由宿主管理真实焦点，这里只记录载荷视角的焦点：同一棵树里同时只有一个控件持有焦点，
     * 变化时回调 {@link OnFocusChangeListener}。
     */
    public boolean requestFocus() {
        if (focused) return true;
        View old = getRootView().findFocus();
        if (old != null && old != this) old.setFocusedInternal(false);
        setFocusedInternal(true);
        return true;
    }

    public void clearFocus() {
        if (focused) setFocusedInternal(false);
    }

    private void setFocusedInternal(boolean value) {
        focused = value;
        OnFocusChangeListener l = onFocusChangeListener;
        if (l != null) l.onFocusChange(this, value);
    }

    public boolean hasFocus() {
        return focused;
    }

    public View findFocus() {
        return focused ? this : null;
    }

    /** 能接收焦点的控件：可聚焦、可见且启用。 */
    public void addFocusables(java.util.ArrayList<View> views, int direction) {
        addFocusables(views, direction, FOCUSABLES_ALL);
    }

    public void addFocusables(java.util.ArrayList<View> views, int direction, int focusableMode) {
        if (views == null || !focusable || visibility != VISIBLE || !enabled) return;
        if (focusableMode == FOCUSABLES_TOUCH_MODE && !focusableInTouchMode) return;
        views.add(this);
    }

    public java.util.ArrayList<View> getFocusables(int direction) {
        java.util.ArrayList<View> result = new java.util.ArrayList<>();
        addFocusables(result, direction);
        return result;
    }

    /** 没有几何布局：优先按 nextFocus*Id，其次按控件树顺序取上一个 / 下一个可聚焦控件。 */
    public View focusSearch(int direction) {
        View root = getRootView();
        int explicit = direction == FOCUS_LEFT ? nextFocusLeftId
                : direction == FOCUS_UP ? nextFocusUpId
                : direction == FOCUS_RIGHT ? nextFocusRightId
                : direction == FOCUS_DOWN ? nextFocusDownId : NO_ID;
        if (explicit != NO_ID) {
            View target = root.findViewById(explicit);
            if (target != null) return target;
        }
        java.util.ArrayList<View> all = root.getFocusables(direction);
        if (all.isEmpty()) return null;
        int index = all.indexOf(this);
        boolean backward = direction == FOCUS_LEFT || direction == FOCUS_UP || direction == FOCUS_BACKWARD;
        int next = index < 0 ? 0 : backward ? index - 1 : index + 1;
        return next >= 0 && next < all.size() ? all.get(next) : null;
    }

    public void setNextFocusLeftId(int id) {
        this.nextFocusLeftId = id;
    }

    public int getNextFocusLeftId() {
        return nextFocusLeftId;
    }

    public void setNextFocusUpId(int id) {
        this.nextFocusUpId = id;
    }

    public int getNextFocusUpId() {
        return nextFocusUpId;
    }

    public void setNextFocusRightId(int id) {
        this.nextFocusRightId = id;
    }

    public int getNextFocusRightId() {
        return nextFocusRightId;
    }

    public void setNextFocusDownId(int id) {
        this.nextFocusDownId = id;
    }

    public int getNextFocusDownId() {
        return nextFocusDownId;
    }

    public void setContentDescription(CharSequence contentDescription) {
        this.contentDescription = contentDescription;
    }

    public CharSequence getContentDescription() {
        return contentDescription;
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
        if (l != null) longClickable = true;
        this.onLongClickListener = l;
    }

    public void setLongClickable(boolean longClickable) {
        this.longClickable = longClickable;
    }

    public boolean isLongClickable() {
        return longClickable;
    }

    public boolean performLongClick() {
        OnLongClickListener l = onLongClickListener;
        return l != null && l.onLongClick(this);
    }

    /** 桌面端不产生触摸事件；子类 super 调用时只按可点击性报告是否消费。 */
    public boolean onTouchEvent(MotionEvent event) {
        return isClickable() || longClickable;
    }

    public boolean dispatchTouchEvent(MotionEvent event) {
        return onTouchEvent(event);
    }

    public void setOnTouchListener(OnTouchListener l) {
    }

    public void setOnKeyListener(OnKeyListener l) {
    }

    public void setOnFocusChangeListener(OnFocusChangeListener l) {
        this.onFocusChangeListener = l;
    }

    public OnFocusChangeListener getOnFocusChangeListener() {
        return onFocusChangeListener;
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

    // 变换属性只保存（供动画与载荷读回），宿主不据此渲染

    public void setScaleX(float scaleX) {
        this.scaleX = scaleX;
    }

    public float getScaleX() {
        return scaleX;
    }

    public void setScaleY(float scaleY) {
        this.scaleY = scaleY;
    }

    public float getScaleY() {
        return scaleY;
    }

    public void setAlpha(float alpha) {
        this.alpha = alpha;
    }

    public float getAlpha() {
        return alpha;
    }

    public void setTranslationX(float translationX) {
        this.translationX = translationX;
    }

    public float getTranslationX() {
        return translationX;
    }

    public void setTranslationY(float translationY) {
        this.translationY = translationY;
    }

    public float getTranslationY() {
        return translationY;
    }

    public void setTranslationZ(float translationZ) {
        this.translationZ = translationZ;
    }

    public float getTranslationZ() {
        return translationZ;
    }

    public void setRotation(float rotation) {
        this.rotation = rotation;
    }

    public float getRotation() {
        return rotation;
    }

    public void setRotationX(float rotationX) {
        this.rotationX = rotationX;
    }

    public float getRotationX() {
        return rotationX;
    }

    public void setRotationY(float rotationY) {
        this.rotationY = rotationY;
    }

    public float getRotationY() {
        return rotationY;
    }

    public void setPivotX(float pivotX) {
        this.pivotX = pivotX;
    }

    public float getPivotX() {
        return pivotX;
    }

    public void setPivotY(float pivotY) {
        this.pivotY = pivotY;
    }

    public float getPivotY() {
        return pivotY;
    }

    /** 每个控件复用同一个属性动画器，与 Android 一致。 */
    public ViewPropertyAnimator animate() {
        synchronized (this) {
            if (animator == null) animator = new ViewPropertyAnimator(this);
            return animator;
        }
    }

    public void clearAnimation() {
    }

    public void setLayerType(int layerType, android.graphics.Paint paint) {
        this.layerType = layerType;
    }

    public int getLayerType() {
        return layerType;
    }

    public void setOverScrollMode(int overScrollMode) {
        this.overScrollMode = overScrollMode;
    }

    public int getOverScrollMode() {
        return overScrollMode;
    }

    public void setSystemUiVisibility(int visibility) {
        this.systemUiVisibility = visibility;
    }

    public int getSystemUiVisibility() {
        return systemUiVisibility;
    }

    public void setFitsSystemWindows(boolean fitSystemWindows) {
        this.fitsSystemWindows = fitSystemWindows;
    }

    public boolean getFitsSystemWindows() {
        return fitsSystemWindows;
    }

    public void setClipToOutline(boolean clipToOutline) {
        this.clipToOutline = clipToOutline;
    }

    public boolean getClipToOutline() {
        return clipToOutline;
    }

    /** 桌面窗口没有状态栏 / 导航栏，系统栏占用一律为 0；未挂到窗口时与 Android 一样返回 null。 */
    public WindowInsets getRootWindowInsets() {
        return attached ? WindowInsets.CONSUMED : null;
    }

    public void computeScroll() {
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
