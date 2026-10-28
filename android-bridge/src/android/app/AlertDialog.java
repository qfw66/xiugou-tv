package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.graphics.drawable.Drawable;
import android.view.View;
import android.widget.Button;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * android.app.AlertDialog 的桌面实现：保存消息、三类按钮与列表项，宿主据此渲染并回传点击。
 *
 * <p>按钮语义与 Android 一致：普通按钮先回调 {@link DialogInterface.OnClickListener} 再自动关闭；
 * 载荷事后用 {@code getButton(which).setOnClickListener(...)} 接管的按钮只回调接管的监听、不自动关闭
 * （载荷常用这种写法在校验失败时保持弹窗）。列表项：普通列表点击后关闭，单选 / 多选只更新选中状态。
 */
public class AlertDialog extends Dialog {

    public static final int ITEMS_NONE = 0;
    public static final int ITEMS_LIST = 1;
    public static final int ITEMS_SINGLE = 2;
    public static final int ITEMS_MULTI = 3;

    private static final int[] BUTTON_ORDER = {BUTTON_NEUTRAL, BUTTON_NEGATIVE, BUTTON_POSITIVE};

    /** 一个对话框按钮：文字、构建期监听与（按需创建的）按钮控件。 */
    private static final class ButtonSpec {
        final CharSequence text;
        final DialogInterface.OnClickListener listener;
        Button view;

        ButtonSpec(CharSequence text, DialogInterface.OnClickListener listener) {
            this.text = text;
            this.listener = listener;
        }
    }

    private volatile CharSequence message;
    private final Map<Integer, ButtonSpec> buttons = new ConcurrentHashMap<>();
    private volatile CharSequence[] items;
    private volatile int itemMode = ITEMS_NONE;
    private volatile int checkedItem = -1;
    private volatile boolean[] checkedItems;
    private DialogInterface.OnClickListener itemListener;
    private DialogInterface.OnMultiChoiceClickListener multiChoiceListener;

    public AlertDialog(Context context) {
        super(context);
    }

    public AlertDialog(Context context, int themeResId) {
        super(context, themeResId);
    }

    protected AlertDialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        super(context, cancelable, cancelListener);
    }

    public void setMessage(CharSequence message) {
        this.message = message;
        DialogHost.get().onDialogChanged(this);
    }

    public void setView(View view) {
        setContentView(view);
    }

    public void setIcon(int resId) {
    }

    public void setIcon(Drawable icon) {
    }

    public void setButton(int whichButton, CharSequence text, DialogInterface.OnClickListener listener) {
        buttons.put(whichButton, new ButtonSpec(text, listener));
        DialogHost.get().onDialogChanged(this);
    }

    public void setButton(CharSequence text, DialogInterface.OnClickListener listener) {
        setButton(BUTTON_POSITIVE, text, listener);
    }

    public void setInverseBackgroundForced(boolean forceInverseBackground) {
    }

    /** 与 Android 一样，只有设置过的按钮才有控件；没有设置返回 null。 */
    public Button getButton(int whichButton) {
        ButtonSpec spec = buttons.get(whichButton);
        if (spec == null) return null;
        synchronized (spec) {
            if (spec.view == null) {
                spec.view = new Button(getContext());
                spec.view.setText(spec.text);
            }
            return spec.view;
        }
    }

    // ---- 宿主访问（桌面扩展，不是 Android API） ----

    public CharSequence getHostMessage() {
        return message;
    }

    /** 按 Android 的排列顺序（中性、否定、肯定）返回已设置的按钮编号。 */
    public int[] getHostButtons() {
        return java.util.Arrays.stream(BUTTON_ORDER).filter(buttons::containsKey).toArray();
    }

    /** 按钮当前文字：控件被载荷改过文字时以控件为准。 */
    public CharSequence getHostButtonText(int which) {
        ButtonSpec spec = buttons.get(which);
        if (spec == null) return null;
        Button view = spec.view;
        return view != null ? view.getText() : spec.text;
    }

    public boolean isHostButtonEnabled(int which) {
        ButtonSpec spec = buttons.get(which);
        Button view = spec == null ? null : spec.view;
        return view == null || view.isEnabled();
    }

    /** {@code view} 是否是本弹窗某个按钮的控件（宿主据此把按钮文字 / 可用性变化归到本弹窗）。 */
    public boolean isHostButton(View view) {
        for (ButtonSpec spec : buttons.values()) {
            if (spec.view == view) return true;
        }
        return false;
    }

    public CharSequence[] getHostItems() {
        return items;
    }

    public int getHostItemMode() {
        return itemMode;
    }

    public int getHostCheckedItem() {
        return checkedItem;
    }

    public boolean[] getHostCheckedItems() {
        return checkedItems;
    }

    /** 用户点了对话框按钮。 */
    public void hostPerformButton(int which) {
        ButtonSpec spec = buttons.get(which);
        if (spec == null) return;
        Button view = spec.view;
        if (view != null && view.getOnClickListener() != null) {
            if (view.isEnabled()) view.performClick();
            return;
        }
        if (spec.listener != null) spec.listener.onClick(this, which);
        dismiss();
    }

    /** 用户点了列表第 {@code index} 项。 */
    public void hostPerformItem(int index) {
        CharSequence[] list = items;
        if (list == null || index < 0 || index >= list.length) return;
        switch (itemMode) {
            case ITEMS_SINGLE:
                checkedItem = index;
                DialogHost.get().onDialogChanged(this);
                if (itemListener != null) itemListener.onClick(this, index);
                break;
            case ITEMS_MULTI: {
                boolean[] checked = checkedItems;
                if (checked == null || index >= checked.length) return;
                checked[index] = !checked[index];
                DialogHost.get().onDialogChanged(this);
                if (multiChoiceListener != null) multiChoiceListener.onClick(this, index, checked[index]);
                break;
            }
            default:
                if (itemListener != null) itemListener.onClick(this, index);
                dismiss();
                break;
        }
    }

    public static class Builder {

        private final Context context;
        private CharSequence title;
        private CharSequence message;
        private View view;
        private boolean cancelable = true;
        private final Map<Integer, ButtonSpec> buttons = new java.util.LinkedHashMap<>();
        private CharSequence[] items;
        private int itemMode = ITEMS_NONE;
        private int checkedItem = -1;
        private boolean[] checkedItems;
        private DialogInterface.OnClickListener itemListener;
        private DialogInterface.OnMultiChoiceClickListener multiChoiceListener;
        private OnDismissListener onDismissListener;
        private OnCancelListener onCancelListener;
        private OnKeyListener onKeyListener;

        public Builder(Context context) {
            this.context = context;
        }

        public Builder(Context context, int themeResId) {
            this.context = context;
        }

        public Context getContext() {
            return context;
        }

        private String string(int resId) {
            return (context != null ? context : Context.get()).getResources().getString(resId);
        }

        public Builder setTitle(CharSequence title) {
            this.title = title;
            return this;
        }

        public Builder setTitle(int titleId) {
            return setTitle(string(titleId));
        }

        public Builder setCustomTitle(View customTitleView) {
            return this;
        }

        public Builder setMessage(CharSequence message) {
            this.message = message;
            return this;
        }

        public Builder setMessage(int messageId) {
            return setMessage(string(messageId));
        }

        public Builder setIcon(int iconId) {
            return this;
        }

        public Builder setIcon(Drawable icon) {
            return this;
        }

        public Builder setPositiveButton(CharSequence text, DialogInterface.OnClickListener listener) {
            buttons.put(BUTTON_POSITIVE, new ButtonSpec(text, listener));
            return this;
        }

        public Builder setPositiveButton(int textId, DialogInterface.OnClickListener listener) {
            return setPositiveButton(string(textId), listener);
        }

        public Builder setNegativeButton(CharSequence text, DialogInterface.OnClickListener listener) {
            buttons.put(BUTTON_NEGATIVE, new ButtonSpec(text, listener));
            return this;
        }

        public Builder setNegativeButton(int textId, DialogInterface.OnClickListener listener) {
            return setNegativeButton(string(textId), listener);
        }

        public Builder setNeutralButton(CharSequence text, DialogInterface.OnClickListener listener) {
            buttons.put(BUTTON_NEUTRAL, new ButtonSpec(text, listener));
            return this;
        }

        public Builder setNeutralButton(int textId, DialogInterface.OnClickListener listener) {
            return setNeutralButton(string(textId), listener);
        }

        public Builder setItems(CharSequence[] items, DialogInterface.OnClickListener listener) {
            this.items = items;
            this.itemMode = ITEMS_LIST;
            this.itemListener = listener;
            return this;
        }

        public Builder setItems(int itemsId, DialogInterface.OnClickListener listener) {
            return this;
        }

        public Builder setSingleChoiceItems(CharSequence[] items, int checkedItem,
                                            DialogInterface.OnClickListener listener) {
            this.items = items;
            this.itemMode = ITEMS_SINGLE;
            this.checkedItem = checkedItem;
            this.itemListener = listener;
            return this;
        }

        public Builder setMultiChoiceItems(CharSequence[] items, boolean[] checkedItems,
                                           DialogInterface.OnMultiChoiceClickListener listener) {
            this.items = items;
            this.itemMode = ITEMS_MULTI;
            this.checkedItems = checkedItems != null ? checkedItems
                    : new boolean[items == null ? 0 : items.length];
            this.multiChoiceListener = listener;
            return this;
        }

        public Builder setView(View view) {
            this.view = view;
            return this;
        }

        public Builder setView(int layoutResId) {
            return this;
        }

        public Builder setCancelable(boolean cancelable) {
            this.cancelable = cancelable;
            return this;
        }

        public Builder setOnDismissListener(OnDismissListener listener) {
            this.onDismissListener = listener;
            return this;
        }

        public Builder setOnCancelListener(OnCancelListener listener) {
            this.onCancelListener = listener;
            return this;
        }

        public Builder setOnKeyListener(OnKeyListener listener) {
            this.onKeyListener = listener;
            return this;
        }

        public AlertDialog create() {
            AlertDialog dialog = new AlertDialog(context);
            dialog.setTitle(title);
            dialog.message = message;
            dialog.buttons.putAll(buttons);
            dialog.items = items;
            dialog.itemMode = itemMode;
            dialog.checkedItem = checkedItem;
            dialog.checkedItems = checkedItems;
            dialog.itemListener = itemListener;
            dialog.multiChoiceListener = multiChoiceListener;
            if (view != null) dialog.setContentView(view);
            dialog.setCancelable(cancelable);
            dialog.setOnDismissListener(onDismissListener);
            dialog.setOnCancelListener(onCancelListener);
            if (onKeyListener != null) dialog.setOnKeyListener(onKeyListener);
            return dialog;
        }

        public AlertDialog show() {
            AlertDialog dialog = create();
            dialog.show();
            return dialog;
        }
    }
}
