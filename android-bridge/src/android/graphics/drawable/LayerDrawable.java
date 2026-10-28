package android.graphics.drawable;

/**
 * android.graphics.drawable.LayerDrawable：多层叠加；桌面端只保存各层与层 id。
 */
public class LayerDrawable extends Drawable {

    private final Drawable[] layers;
    private final int[] ids;

    public LayerDrawable(Drawable[] layers) {
        this.layers = layers == null ? new Drawable[0] : layers.clone();
        this.ids = new int[this.layers.length];
    }

    public int getNumberOfLayers() {
        return layers.length;
    }

    public Drawable getDrawable(int index) {
        return index >= 0 && index < layers.length ? layers[index] : null;
    }

    public void setId(int index, int id) {
        if (index >= 0 && index < ids.length) ids[index] = id;
    }

    public Drawable findDrawableByLayerId(int id) {
        for (int i = 0; i < ids.length; i++) {
            if (ids[i] == id) return layers[i];
        }
        return null;
    }
}
