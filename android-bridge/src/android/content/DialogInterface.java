package android.content;

import android.view.KeyEvent;

/**
 * android.content.DialogInterface：弹窗回调契约（与 AOSP 签名一致）。
 */
public interface DialogInterface {

    int BUTTON_POSITIVE = -1;
    int BUTTON_NEGATIVE = -2;
    int BUTTON_NEUTRAL = -3;

    void cancel();

    void dismiss();

    interface OnClickListener {
        void onClick(DialogInterface dialog, int which);
    }

    interface OnMultiChoiceClickListener {
        void onClick(DialogInterface dialog, int which, boolean isChecked);
    }

    interface OnCancelListener {
        void onCancel(DialogInterface dialog);
    }

    interface OnDismissListener {
        void onDismiss(DialogInterface dialog);
    }

    interface OnShowListener {
        void onShow(DialogInterface dialog);
    }

    interface OnKeyListener {
        boolean onKey(DialogInterface dialog, int keyCode, KeyEvent event);
    }
}
