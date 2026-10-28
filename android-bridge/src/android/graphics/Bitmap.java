package android.graphics;

import javax.imageio.ImageIO;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;

/**
 * android.graphics.Bitmap 的桌面实现：像素存放在 {@code TYPE_INT_ARGB} 的 {@link BufferedImage} 里，
 * 与 Android 的 ARGB_8888 布局一致，{@link Canvas} 直接用 Java2D 在上面绘制。
 *
 * <p>载荷用 zxing 生成登录二维码后写进本类，宿主再编码成 PNG 交给 Flutter 显示，所以像素必须真实保存。
 */
public final class Bitmap {

    public enum Config {
        ALPHA_8,
        RGB_565,
        ARGB_4444,
        ARGB_8888,
        RGBA_F16,
        HARDWARE
    }

    public enum CompressFormat {
        JPEG,
        PNG,
        WEBP,
        WEBP_LOSSY,
        WEBP_LOSSLESS
    }

    private final BufferedImage image;
    private final Config config;
    private boolean recycled;
    private int density = 160;
    /** 像素修改计数，宿主据此判断缓存的 PNG 是否过期。 */
    private volatile int version;
    private int pngVersion = -1;
    private byte[] pngCache;

    private Bitmap(int width, int height, Config config) {
        this.image = new BufferedImage(Math.max(1, width), Math.max(1, height), BufferedImage.TYPE_INT_ARGB);
        this.config = config == null ? Config.ARGB_8888 : config;
    }

    /** 由解码好的图像构造（{@link BitmapFactory} 使用）。 */
    static Bitmap fromImage(BufferedImage src) {
        Bitmap b = new Bitmap(src.getWidth(), src.getHeight(), Config.ARGB_8888);
        Graphics2D g = b.image.createGraphics();
        try {
            g.drawImage(src, 0, 0, null);
        } finally {
            g.dispose();
        }
        return b;
    }

    public static Bitmap createBitmap(int width, int height, Config config) {
        if (width <= 0 || height <= 0) throw new IllegalArgumentException("width and height must be > 0");
        return new Bitmap(width, height, config);
    }

    public static Bitmap createBitmap(int[] colors, int width, int height, Config config) {
        return createBitmap(colors, 0, width, width, height, config);
    }

    public static Bitmap createBitmap(int[] colors, int offset, int stride, int width, int height, Config config) {
        Bitmap b = createBitmap(width, height, config);
        b.setPixels(colors, offset, stride, 0, 0, width, height);
        return b;
    }

    public static Bitmap createBitmap(Bitmap src) {
        return createBitmap(src, 0, 0, src.getWidth(), src.getHeight());
    }

    public static Bitmap createBitmap(Bitmap src, int x, int y, int width, int height) {
        return createBitmap(src, x, y, width, height, null, false);
    }

    public static Bitmap createBitmap(Bitmap src, int x, int y, int width, int height, Matrix m, boolean filter) {
        BufferedImage region = src.image.getSubimage(x, y, width, height);
        java.awt.geom.AffineTransform t = m == null ? new java.awt.geom.AffineTransform() : m.toAffine();
        java.awt.geom.Rectangle2D bounds = t.createTransformedShape(
                new java.awt.Rectangle(0, 0, width, height)).getBounds2D();
        int outW = Math.max(1, (int) Math.round(bounds.getWidth()));
        int outH = Math.max(1, (int) Math.round(bounds.getHeight()));
        Bitmap out = new Bitmap(outW, outH, src.config);
        Graphics2D g = out.image.createGraphics();
        try {
            if (filter) {
                g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
            }
            g.translate(-bounds.getX(), -bounds.getY());
            g.transform(t);
            g.drawImage(region, 0, 0, null);
        } finally {
            g.dispose();
        }
        return out;
    }

    public static Bitmap createScaledBitmap(Bitmap src, int dstWidth, int dstHeight, boolean filter) {
        Bitmap out = createBitmap(dstWidth, dstHeight, src.config);
        Graphics2D g = out.image.createGraphics();
        try {
            if (filter) {
                g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
            }
            g.drawImage(src.image, 0, 0, dstWidth, dstHeight, null);
        } finally {
            g.dispose();
        }
        return out;
    }

    public int getWidth() {
        return image.getWidth();
    }

    public int getHeight() {
        return image.getHeight();
    }

    public Config getConfig() {
        return config;
    }

    public boolean hasAlpha() {
        return true;
    }

    public void setHasAlpha(boolean hasAlpha) {
    }

    public boolean isMutable() {
        return true;
    }

    public boolean isRecycled() {
        return recycled;
    }

    public void recycle() {
        recycled = true;
    }

    public void prepareToDraw() {
    }

    public int getDensity() {
        return density;
    }

    public void setDensity(int density) {
        this.density = density;
    }

    public int getRowBytes() {
        return getWidth() * 4;
    }

    public int getByteCount() {
        return getRowBytes() * getHeight();
    }

    public int getAllocationByteCount() {
        return getByteCount();
    }

    public Bitmap copy(Config config, boolean isMutable) {
        Bitmap out = new Bitmap(getWidth(), getHeight(), config);
        Graphics2D g = out.image.createGraphics();
        try {
            g.drawImage(image, 0, 0, null);
        } finally {
            g.dispose();
        }
        return out;
    }

    public int getPixel(int x, int y) {
        return image.getRGB(x, y);
    }

    public void setPixel(int x, int y, int color) {
        image.setRGB(x, y, color);
        touch();
    }

    public void getPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        image.getRGB(x, y, width, height, pixels, offset, stride);
    }

    public void setPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        image.setRGB(x, y, width, height, pixels, offset, stride);
        touch();
    }

    public void eraseColor(int color) {
        int[] row = new int[getWidth()];
        java.util.Arrays.fill(row, color);
        for (int y = 0; y < getHeight(); y++) image.setRGB(0, y, row.length, 1, row, 0, row.length);
        touch();
    }

    public boolean compress(CompressFormat format, int quality, OutputStream stream) {
        if (stream == null || recycled) return false;
        try {
            if (format == CompressFormat.JPEG) {
                BufferedImage rgb = new BufferedImage(getWidth(), getHeight(), BufferedImage.TYPE_INT_RGB);
                Graphics2D g = rgb.createGraphics();
                try {
                    g.setColor(java.awt.Color.WHITE);
                    g.fillRect(0, 0, getWidth(), getHeight());
                    g.drawImage(image, 0, 0, null);
                } finally {
                    g.dispose();
                }
                return ImageIO.write(rgb, "jpg", stream);
            }
            // ImageIO 不能写 WebP：统一输出无损 PNG（载荷只是拿去 Base64 / 落盘，格式不敏感）
            return ImageIO.write(image, "png", stream);
        } catch (IOException e) {
            return false;
        }
    }

    // ---- 桌面扩展 ----

    /** 供 {@link Canvas} 直接在像素上绘制。 */
    BufferedImage image() {
        return image;
    }

    /** 像素被修改后调用，令缓存的 PNG 失效。 */
    void touch() {
        version++;
    }

    /** 编码为 PNG（宿主把它交给 Flutter）；像素未变时复用上次结果。 */
    public synchronized byte[] toPng() {
        int v = version;
        if (pngCache != null && pngVersion == v) return pngCache;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try {
            ImageIO.write(image, "png", out);
        } catch (IOException e) {
            return new byte[0];
        }
        pngCache = out.toByteArray();
        pngVersion = v;
        return pngCache;
    }
}
