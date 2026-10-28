package android.graphics;

import java.awt.geom.AffineTransform;

/**
 * android.graphics.Matrix：以 {@link AffineTransform} 实现（pre 为右乘、post 为左乘，与 Android 一致）。
 */
public class Matrix {

    private AffineTransform transform = new AffineTransform();

    public Matrix() {
    }

    public Matrix(Matrix src) {
        if (src != null) transform = new AffineTransform(src.transform);
    }

    /** 供 {@link Canvas} / {@link Bitmap} 使用。 */
    AffineTransform toAffine() {
        return new AffineTransform(transform);
    }

    public void reset() {
        transform.setToIdentity();
    }

    public boolean isIdentity() {
        return transform.isIdentity();
    }

    public void set(Matrix src) {
        transform = src == null ? new AffineTransform() : new AffineTransform(src.transform);
    }

    public void setScale(float sx, float sy) {
        transform.setToScale(sx, sy);
    }

    public void setTranslate(float dx, float dy) {
        transform.setToTranslation(dx, dy);
    }

    public void setRotate(float degrees) {
        transform.setToRotation(Math.toRadians(degrees));
    }

    public boolean preScale(float sx, float sy) {
        transform.scale(sx, sy);
        return true;
    }

    public boolean preTranslate(float dx, float dy) {
        transform.translate(dx, dy);
        return true;
    }

    public boolean preRotate(float degrees) {
        transform.rotate(Math.toRadians(degrees));
        return true;
    }

    public boolean postScale(float sx, float sy) {
        return post(AffineTransform.getScaleInstance(sx, sy));
    }

    public boolean postScale(float sx, float sy, float px, float py) {
        AffineTransform t = AffineTransform.getTranslateInstance(px, py);
        t.scale(sx, sy);
        t.translate(-px, -py);
        return post(t);
    }

    public boolean postTranslate(float dx, float dy) {
        return post(AffineTransform.getTranslateInstance(dx, dy));
    }

    public boolean postRotate(float degrees) {
        return post(AffineTransform.getRotateInstance(Math.toRadians(degrees)));
    }

    public boolean postRotate(float degrees, float px, float py) {
        return post(AffineTransform.getRotateInstance(Math.toRadians(degrees), px, py));
    }

    private boolean post(AffineTransform left) {
        left.concatenate(transform);
        transform = left;
        return true;
    }
}
