package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;

import java.util.concurrent.atomic.AtomicInteger;

/**
 * android.app.Dialog 的桌面实现：保存标题、内容视图与监听器，显示 / 关闭时通知 {@link DialogHost}。
 *
 * <p>生命周期与 Android 一致：首次 {@link #show()} 前调用 {@link #onCreate}（自定义弹窗在这里
 * {@code setContentView}）；{@link #cancel()} 先回调取消监听再关闭；关闭时回调关闭监听。
 */
public class Dialog implements DialogInterface {

    public static final int BUTTON_POSITIVE = -1;
    public static final int BUTTON_NEGATIVE = -2;
    public static final int BUTTON_NEUTRAL = -3;

    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);

    private final int hostId = NEXT_ID.getAndIncrement();
    private final Context context;
    private final Window window = new Window(this::setContentView);
    private volatile CharSequence title;
    private volatile View contentView;
    private volatile boolean showing;
    private boolean created;
    private boolean cancelable = true;
    private OnDismissListener onDismissListener;
    private OnCancelListener onCancelListener;
    private OnShowListener onShowListener;
    private OnKeyListener onKeyListener;

    public Dialog(Context context) {
        this.context = context;
    }

    public Dialog(Context context, int themeResId) {
        this.context = context;
    }

    protected Dialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        this.context = context;
        this.cancelable = cancelable;
        this.onCancelListener = cancelListener;
    }

    // ---- 生命周期 ----

    protected void onCreate(android.os.Bundle savedInstanceState) {
    }

    protected void onStart() {
    }

    protected void onStop() {
    }

    public void onAttachedToWindow() {
    }

    public void onDetachedFromWindow() {
    }

    public void create() {
        if (!created) {
            created = true;
            onCreate(null);
        }
    }

    public void show() {
        if (showing) return;
        create();
        showing = true;
        onStart();
        View content = contentView;
        if (content != null) content.dispatchAttached(true);
        onAttachedToWindow();
        DialogHost.get().onShow(this);
        if (onShowListener != null) onShowListener.onShow(this);
    }

    @Override
    public void dismiss() {
        if (!showing) return;
        showing = false;
        View content = contentView;
        if (content != null) content.dispatchAttached(false);
        onDetachedFromWindow();
        onStop();
        DialogHost.get().onDismiss(this);
        if (onDismissListener != null) onDismissListener.onDismiss(this);
    }

    @Override
    public void cancel() {
        if (onCancelListener != null) onCancelListener.onCancel(this);
        dismiss();
    }

    public void hide() {
        dismiss();
    }

    public boolean isShowing() {
        return showing;
    }

    // ---- 内容 ----

    public void setTitle(CharSequence title) {
        this.title = title;
        DialogHost.get().onDialogChanged(this);
    }

    public void setTitle(int titleId) {
        setTitle(getContext().getResources().getString(titleId));
    }

    public void setContentView(View view) {
        View old = contentView;
        if (old == view) return;
        if (old != null && showing) old.dispatchAttached(false);
        contentView = view;
        if (view != null && showing) view.dispatchAttached(true);
        DialogHost.get().onDialogChanged(this);
    }

    public void setContentView(View view, ViewGroup.LayoutParams params) {
        if (view != null && params != null) view.setLayoutParams(params);
        setContentView(view);
    }

    public void setContentView(int layoutResID) {
    }

    public View findViewById(int id) {
        View content = contentView;
        return content == null ? null : content.findViewById(id);
    }

    public final boolean requestWindowFeature(int featureId) {
        return true;
    }

    public Window getWindow() {
        return window;
    }

    public Context getContext() {
        return context != null ? context : Context.get();
    }

    // ---- 监听与可取消 ----

    public void setCancelable(boolean flag) {
        this.cancelable = flag;
    }

    public void setCanceledOnTouchOutside(boolean cancel) {
    }

    public void setOnDismissListener(OnDismissListener listener) {
        this.onDismissListener = listener;
    }

    public void setOnCancelListener(OnCancelListener listener) {
        this.onCancelListener = listener;
    }

    public void setOnShowListener(OnShowListener listener) {
        this.onShowListener = listener;
    }

    public void setOnKeyListener(OnKeyListener onKeyListener) {
        this.onKeyListener = onKeyListener;
    }

    // ---- 宿主访问（桌面扩展，不是 Android API） ----

    public final int getHostId() {
        return hostId;
    }

    public CharSequence getHostTitle() {
        return title;
    }

    public View getHostContentView() {
        return contentView;
    }

    public boolean isHostCancelable() {
        return cancelable;
    }

    /**
     * 用户在宿主侧关闭弹窗（Esc / 点关闭）：先按 Android 的返回键语义询问按键监听，
     * 未被拦截且可取消时执行 {@link #cancel()}。
     */
    public void hostRequestCancel() {
        if (onKeyListener != null && onKeyListener.onKey(this, KeyEvent.KEYCODE_BACK, null)) return;
        if (cancelable) cancel();
    }
}
