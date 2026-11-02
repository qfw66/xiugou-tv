package android.media;

import android.graphics.Bitmap;

/**
 * 缩略图工具。桌面端没有视频解码器，createVideoThumbnail 与 Android 解码失败时一样返回 null，
 * 载荷按「无缩略图」处理。
 */
public class ThumbnailUtils {

    public static final int OPTIONS_RECYCLE_INPUT = 0x2;

    public static Bitmap createVideoThumbnail(String filePath, int kind) {
        return null;
    }

    /** 居中裁剪并缩放到目标尺寸。 */
    public static Bitmap extractThumbnail(Bitmap source, int width, int height) {
        return extractThumbnail(source, width, height, 0);
    }

    public static Bitmap extractThumbnail(Bitmap source, int width, int height, int options) {
        if (source == null || width <= 0 || height <= 0) return null;
        float scale = Math.max((float) width / source.getWidth(), (float) height / source.getHeight());
        int scaledW = Math.max(1, Math.round(source.getWidth() * scale));
        int scaledH = Math.max(1, Math.round(source.getHeight() * scale));
        Bitmap scaled = Bitmap.createScaledBitmap(source, scaledW, scaledH, true);
        int x = Math.max(0, (scaledW - width) / 2);
        int y = Math.max(0, (scaledH - height) / 2);
        return Bitmap.createBitmap(scaled, x, y, Math.min(width, scaledW), Math.min(height, scaledH));
    }
}
