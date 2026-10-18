package android.widget;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.drawable.Drawable;
import android.view.View;

/**
 * Minimal android.widget.ImageView stub。
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

    public ImageView(Context context) {
        super(context);
    }

    public void setImageBitmap(Bitmap bitmap) {
    }

    public void setImageResource(int resId) {
    }

    public void setImageDrawable(Drawable drawable) {
    }

    public void setScaleType(ScaleType scaleType) {
    }

    public void setAdjustViewBounds(boolean adjustViewBounds) {
    }
}
