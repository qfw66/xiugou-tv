package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * 拖动条：进度变化时按 Android 语义回调 {@link OnSeekBarChangeListener}（fromUser=false，
 * 因为桌面端的进度只会由载荷代码设置）。
 */
public class SeekBar extends AbsSeekBar {

    private OnSeekBarChangeListener listener;

    public SeekBar(Context context) {
        super(context);
        setMax(100);
    }

    public SeekBar(Context context, AttributeSet attrs) {
        super(context, attrs);
        setMax(100);
    }

    public SeekBar(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        setMax(100);
    }

    public void setOnSeekBarChangeListener(OnSeekBarChangeListener l) {
        this.listener = l;
    }

    @Override
    public synchronized void setProgress(int progress) {
        int old = getProgress();
        super.setProgress(progress);
        OnSeekBarChangeListener l = listener;
        if (l != null && getProgress() != old) l.onProgressChanged(this, getProgress(), false);
    }

    public interface OnSeekBarChangeListener {
        void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser);

        void onStartTrackingTouch(SeekBar seekBar);

        void onStopTrackingTouch(SeekBar seekBar);
    }
}
