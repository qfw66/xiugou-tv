package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.graphics.drawable.Drawable;
import android.view.View;
import android.widget.Button;

/**
 * Minimal android.app.AlertDialog stub（Builder 全部 no-op）。
 */
public class AlertDialog extends Dialog {

    public AlertDialog(Context context) {
        super(context);
    }

    public AlertDialog(Context context, int themeResId) {
        super(context, themeResId);
    }

    public void setMessage(CharSequence message) {
    }

    public void setView(View view) {
    }

    public void setIcon(int resId) {
    }

    public void setIcon(Drawable icon) {
    }

    public void setButton(int whichButton, CharSequence text, OnClickListener listener) {
    }

    public void setButton(CharSequence text, OnClickListener listener) {
    }

    public void setInverseBackgroundForced(boolean forceInverseBackground) {
    }

    public Button getButton(int whichButton) {
        return null;
    }

    public static class Builder {

        private final Context context;

        public Builder(Context context) {
            this.context = context;
        }

        public Context getContext() {
            return context;
        }

        public Builder setTitle(CharSequence title) {
            return this;
        }

        public Builder setTitle(int titleId) {
            return this;
        }

        public Builder setMessage(CharSequence message) {
            return this;
        }

        public Builder setMessage(int messageId) {
            return this;
        }

        public Builder setIcon(int iconId) {
            return this;
        }

        public Builder setIcon(Drawable icon) {
            return this;
        }

        public Builder setPositiveButton(CharSequence text, OnClickListener listener) {
            return this;
        }

        public Builder setPositiveButton(int textId, OnClickListener listener) {
            return this;
        }

        public Builder setNegativeButton(CharSequence text, OnClickListener listener) {
            return this;
        }

        public Builder setNegativeButton(int textId, OnClickListener listener) {
            return this;
        }

        public Builder setNeutralButton(CharSequence text, OnClickListener listener) {
            return this;
        }

        public Builder setNeutralButton(int textId, OnClickListener listener) {
            return this;
        }

        public Builder setItems(CharSequence[] items, OnClickListener listener) {
            return this;
        }

        public Builder setItems(int itemsId, OnClickListener listener) {
            return this;
        }

        public Builder setSingleChoiceItems(CharSequence[] items, int checkedItem, OnClickListener listener) {
            return this;
        }

        public Builder setMultiChoiceItems(CharSequence[] items, boolean[] checkedItems, OnMultiChoiceClickListener listener) {
            return this;
        }

        public Builder setView(View view) {
            return this;
        }

        public Builder setCancelable(boolean cancelable) {
            return this;
        }

        public Builder setOnDismissListener(OnDismissListener listener) {
            return this;
        }

        public Builder setOnCancelListener(OnCancelListener listener) {
            return this;
        }

        public AlertDialog create() {
            return new AlertDialog(context);
        }

        public AlertDialog show() {
            AlertDialog dialog = create();
            dialog.show();
            return dialog;
        }
    }

    public interface OnMultiChoiceClickListener {
        void onClick(DialogInterface dialog, int which, boolean isChecked);
    }
}
