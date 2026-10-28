package android.graphics.drawable;

import android.graphics.Bitmap;
import android.graphics.Canvas;

/**
 * android.graphics.drawable.BitmapDrawable：持有位图，{@code ImageView.setImageDrawable} 时宿主据此显示图片。
 */
public class BitmapDrawable extends Drawable {

    private final Bitmap bitmap;

    public BitmapDrawable(Bitmap bitmap) {
        this.bitmap = bitmap;
    }

    public BitmapDrawable(android.content.res.Resources res, Bitmap bitmap) {
        this.bitmap = bitmap;
    }

    public final Bitmap getBitmap() {
        return bitmap;
    }

    @Override
    public int getIntrinsicWidth() {
        return bitmap == null ? 0 : bitmap.getWidth();
    }

    @Override
    public int getIntrinsicHeight() {
        return bitmap == null ? 0 : bitmap.getHeight();
    }

    @Override
    public void draw(Canvas canvas) {
        if (canvas != null && bitmap != null) canvas.drawBitmap(bitmap, getBounds().left, getBounds().top, null);
    }
}
