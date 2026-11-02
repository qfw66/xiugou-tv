package android.view;

import android.graphics.drawable.Drawable;

/**
 * android.view.Window 的桌面实现。
 *
 * <p>弹窗常写 {@code dialog.getWindow().setContentView(view)}，所以窗口要能把内容视图交回所属弹窗；
 * 尺寸、背景、标志位等与呈现无关，保持空实现。
 */
public class Window {

    /** 所属弹窗收内容视图的回调（桌面扩展）；Activity 的窗口为 null。 */
    public interface ContentSink {
        void setContentView(View view);
    }

    private final ContentSink sink;
    private final WindowManager.LayoutParams attributes = new WindowManager.LayoutParams();
    private View decorView;
    private int statusBarColor;
    private int navigationBarColor;
    private boolean navigationBarContrastEnforced = true;
    private final android.window.OnBackInvokedDispatcher backDispatcher = new android.window.OnBackInvokedDispatcher();

    public Window() {
        this(null);
    }

    public Window(ContentSink sink) {
        this.sink = sink;
    }

    public View getDecorView() {
        if (decorView == null) decorView = new android.widget.FrameLayout(null);
        return decorView;
    }

    public void setContentView(View view) {
        if (sink != null) sink.setContentView(view);
    }

    public void setContentView(int layoutResID) {
    }

    public void setLayout(int width, int height) {
    }

    public void setGravity(int gravity) {
    }

    public void setFlags(int flags, int mask) {
    }

    public void clearFlags(int flags) {
    }

    public void addFlags(int flags) {
    }

    public void setBackgroundDrawable(Drawable drawable) {
    }

    public void setBackgroundDrawableResource(int resId) {
    }

    public void setDimAmount(float amount) {
    }

    public void setType(int type) {
    }

    public void setSoftInputMode(int mode) {
    }

    public void setWindowAnimations(int resId) {
    }

    public WindowManager.LayoutParams getAttributes() {
        return attributes;
    }

    public void setAttributes(WindowManager.LayoutParams params) {
    }

    public void setStatusBarColor(int color) {
        this.statusBarColor = color;
    }

    public int getStatusBarColor() {
        return statusBarColor;
    }

    public void setNavigationBarColor(int color) {
        this.navigationBarColor = color;
    }

    public int getNavigationBarColor() {
        return navigationBarColor;
    }

    public void setNavigationBarContrastEnforced(boolean enforceContrast) {
        this.navigationBarContrastEnforced = enforceContrast;
    }

    public boolean isNavigationBarContrastEnforced() {
        return navigationBarContrastEnforced;
    }

    /** 每个窗口一个返回手势分发器；桌面端的返回由宿主的「关闭弹窗」承担。 */
    public android.window.OnBackInvokedDispatcher getOnBackInvokedDispatcher() {
        return backDispatcher;
    }

    public View getCurrentFocus() {
        return decorView == null ? null : decorView.findFocus();
    }

    public View findViewById(int id) {
        return decorView == null ? null : decorView.findViewById(id);
    }
}
