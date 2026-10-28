package android.widget;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;
import android.view.View;

/**
 * android.widget.ProgressBar：宿主渲染为进度条；未设置过 max / progress 时视为不确定进度（转圈）。
 */
public class ProgressBar extends View {

    private volatile int max = 100;
    private volatile int progress;
    private volatile boolean indeterminate = true;
    private Drawable progressDrawable;
    private Drawable indeterminateDrawable;

    public ProgressBar(Context context) {
        super(context);
    }

    public ProgressBar(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public ProgressBar(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public synchronized void setMax(int max) {
        this.max = Math.max(0, max);
        this.indeterminate = false;
        notifyChanged();
    }

    public int getMax() {
        return max;
    }

    public synchronized void setProgress(int progress) {
        this.progress = Math.max(0, Math.min(progress, max));
        this.indeterminate = false;
        notifyChanged();
    }

    public int getProgress() {
        return progress;
    }

    public void setIndeterminate(boolean indeterminate) {
        this.indeterminate = indeterminate;
        notifyChanged();
    }

    public boolean isIndeterminate() {
        return indeterminate;
    }

    public void setProgressDrawable(Drawable d) {
        this.progressDrawable = d;
    }

    public Drawable getProgressDrawable() {
        return progressDrawable;
    }

    public void setIndeterminateDrawable(Drawable d) {
        this.indeterminateDrawable = d;
    }

    public Drawable getIndeterminateDrawable() {
        return indeterminateDrawable;
    }
}
