package android.widget;

import android.content.Context;
import android.util.AttributeSet;

/**
 * 可拖动进度条基类。宿主按 {@link ProgressBar} 渲染（只读进度）；按键步长如实保存。
 */
public abstract class AbsSeekBar extends ProgressBar {

    private int keyProgressIncrement = 1;
    private android.graphics.drawable.Drawable thumb;

    public AbsSeekBar(Context context) {
        super(context);
    }

    public AbsSeekBar(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public AbsSeekBar(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void setKeyProgressIncrement(int increment) {
        this.keyProgressIncrement = increment < 0 ? -increment : increment;
    }

    public int getKeyProgressIncrement() {
        return keyProgressIncrement;
    }

    public void setThumb(android.graphics.drawable.Drawable thumb) {
        this.thumb = thumb;
    }

    public android.graphics.drawable.Drawable getThumb() {
        return thumb;
    }

    public void setThumbTintList(android.content.res.ColorStateList tint) {
    }

    public void setSplitTrack(boolean splitTrack) {
    }
}
