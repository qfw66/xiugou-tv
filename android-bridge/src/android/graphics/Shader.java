package android.graphics;

/**
 * android.graphics.Shader：渐变等着色器的基类；子类提供对应的 Java2D 画笔。
 */
public class Shader {

    public enum TileMode {
        CLAMP,
        REPEAT,
        MIRROR,
        DECAL
    }

    private Matrix localMatrix;

    public void setLocalMatrix(Matrix localM) {
        this.localMatrix = localM == null ? null : new Matrix(localM);
    }

    public boolean getLocalMatrix(Matrix localM) {
        if (localMatrix == null || localM == null) return false;
        localM.set(localMatrix);
        return true;
    }

    /** 对应的 Java2D 画笔；基类无效果，返回 null 表示退回纯色。 */
    java.awt.Paint toAwtPaint() {
        return null;
    }
}
