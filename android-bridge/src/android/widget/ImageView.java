package android.widget;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;
import android.view.View;

/**
 * android.widget.ImageView 的桌面实现：保存位图（登录二维码就放在这里），宿主编码成 PNG 显示。
 */
public class ImageView extends View {

    public enum ScaleType {
        MATRIX,
        FIT_XY,
        FIT_START,
        FIT_CENTER,
        FIT_END,
        CENTER,
        CENTER_CROP,
        CENTER_INSIDE
    }

    private volatile Bitmap bitmap;
    private Drawable drawable;
    private ScaleType scaleType = ScaleType.FIT_CENTER;

    public ImageView(Context context) {
        super(context);
    }

    public ImageView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public ImageView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void setImageBitmap(Bitmap bitmap) {
        this.bitmap = bitmap;
        this.drawable = bitmap == null ? null : new BitmapDrawable(bitmap);
        notifyChanged();
    }

    public void setImageDrawable(Drawable drawable) {
        this.drawable = drawable;
        this.bitmap = drawable instanceof BitmapDrawable ? ((BitmapDrawable) drawable).getBitmap() : null;
        notifyChanged();
    }

    public Drawable getDrawable() {
        return drawable;
    }

    /** 当前显示的位图（桌面扩展：宿主据此导出图片）。 */
    public Bitmap getImageBitmap() {
        return bitmap;
    }

    public void setImageResource(int resId) {
    }

    public void setScaleType(ScaleType scaleType) {
        if (scaleType != null) this.scaleType = scaleType;
    }

    public ScaleType getScaleType() {
        return scaleType;
    }

    public void setAdjustViewBounds(boolean adjustViewBounds) {
    }

    public void setMaxWidth(int maxWidth) {
    }

    public void setMaxHeight(int maxHeight) {
    }

    public void setColorFilter(int color) {
    }
}
