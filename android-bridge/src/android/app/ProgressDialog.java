package android.app;

import android.content.Context;
import android.widget.ProgressBar;

/** Android progress-dialog API backed by the existing desktop dialog/view event channel. */
public class ProgressDialog extends AlertDialog {
    public static final int STYLE_SPINNER = 0;
    public static final int STYLE_HORIZONTAL = 1;

    private final ProgressBar progressBar;
    private int progressStyle = STYLE_SPINNER;
    private boolean indeterminate;

    public ProgressDialog(Context context) {
        this(context, 0);
    }

    public ProgressDialog(Context context, int themeResId) {
        super(context, themeResId);
        progressBar = new ProgressBar(getContext());
        setView(progressBar);
    }

    public synchronized void setProgressStyle(int style) {
        progressStyle = style;
        updateMode();
    }

    public synchronized void setMax(int max) {
        int boundedMax = Math.max(0, max);
        if (progressBar.getProgress() > boundedMax) progressBar.setProgress(boundedMax);
        progressBar.setMax(boundedMax);
        updateMode();
    }

    public int getMax() {
        return progressBar.getMax();
    }

    public synchronized void setProgress(int value) {
        progressBar.setProgress(value);
        updateMode();
    }

    public int getProgress() {
        return progressBar.getProgress();
    }

    public synchronized void setIndeterminate(boolean value) {
        indeterminate = value;
        updateMode();
    }

    public boolean isIndeterminate() {
        return progressBar.isIndeterminate();
    }

    private void updateMode() {
        progressBar.setIndeterminate(progressStyle != STYLE_HORIZONTAL || indeterminate);
    }
}
