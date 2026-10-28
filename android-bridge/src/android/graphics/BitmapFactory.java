package android.graphics;

import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.stream.ImageInputStream;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.Iterator;

/**
 * android.graphics.BitmapFactory：用 ImageIO 解码（PNG / JPEG / GIF / BMP）。
 *
 * <p>解码失败返回 null，与 Android 一致；ImageIO 不支持 WebP，这类图片同样返回 null。
 */
public class BitmapFactory {

    public static class Options {
        public boolean inJustDecodeBounds;
        public int inSampleSize = 1;
        public Bitmap.Config inPreferredConfig = Bitmap.Config.ARGB_8888;
        public boolean inMutable;
        public boolean inScaled = true;
        public int inDensity;
        public int inTargetDensity;
        public int outWidth = -1;
        public int outHeight = -1;
        public String outMimeType;
    }

    public static Bitmap decodeByteArray(byte[] data, int offset, int length) {
        return decodeByteArray(data, offset, length, null);
    }

    public static Bitmap decodeByteArray(byte[] data, int offset, int length, Options opts) {
        if (data == null || length <= 0) return null;
        return decode(new ByteArrayInputStream(data, offset, length), opts);
    }

    public static Bitmap decodeStream(InputStream is) {
        return decodeStream(is, null, null);
    }

    public static Bitmap decodeStream(InputStream is, Rect outPadding, Options opts) {
        return is == null ? null : decode(is, opts);
    }

    public static Bitmap decodeFile(String pathName) {
        return decodeFile(pathName, null);
    }

    public static Bitmap decodeFile(String pathName, Options opts) {
        if (pathName == null) return null;
        try (InputStream in = new java.io.FileInputStream(new File(pathName))) {
            return decode(in, opts);
        } catch (IOException e) {
            return null;
        }
    }

    public static Bitmap decodeResource(android.content.res.Resources res, int id) {
        return null;
    }

    public static Bitmap decodeResource(android.content.res.Resources res, int id, Options opts) {
        return null;
    }

    private static Bitmap decode(InputStream in, Options opts) {
        try (ImageInputStream iis = ImageIO.createImageInputStream(in)) {
            if (iis == null) return null;
            Iterator<ImageReader> readers = ImageIO.getImageReaders(iis);
            if (!readers.hasNext()) return null;
            ImageReader reader = readers.next();
            try {
                reader.setInput(iis, true, true);
                if (opts != null) {
                    opts.outWidth = reader.getWidth(0);
                    opts.outHeight = reader.getHeight(0);
                    opts.outMimeType = mimeOf(reader.getFormatName());
                    if (opts.inJustDecodeBounds) return null;
                }
                BufferedImage img = reader.read(0);
                if (img == null) return null;
                Bitmap bitmap = Bitmap.fromImage(img);
                int sample = opts == null ? 1 : Integer.highestOneBit(Math.max(1, opts.inSampleSize));
                if (sample > 1) {
                    bitmap = Bitmap.createScaledBitmap(bitmap, Math.max(1, img.getWidth() / sample),
                            Math.max(1, img.getHeight() / sample), true);
                }
                return bitmap;
            } finally {
                reader.dispose();
            }
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }

    private static String mimeOf(String format) {
        if (format == null) return null;
        String f = format.toLowerCase(java.util.Locale.ROOT);
        if (f.contains("jpeg") || f.equals("jpg")) return "image/jpeg";
        return "image/" + f;
    }
}
