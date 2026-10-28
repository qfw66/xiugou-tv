package android.graphics;

/**
 * android.graphics.Typeface：只记录字体族与粗斜体，由 {@link Paint} 映射成 Java2D 字体。
 */
public class Typeface {

    public static final int NORMAL = 0;
    public static final int BOLD = 1;
    public static final int ITALIC = 2;
    public static final int BOLD_ITALIC = 3;

    public static final Typeface DEFAULT = new Typeface("SansSerif", NORMAL);
    public static final Typeface DEFAULT_BOLD = new Typeface("SansSerif", BOLD);
    public static final Typeface SANS_SERIF = new Typeface("SansSerif", NORMAL);
    public static final Typeface SERIF = new Typeface("Serif", NORMAL);
    public static final Typeface MONOSPACE = new Typeface("Monospaced", NORMAL);

    private final String family;
    private final int style;

    private Typeface(String family, int style) {
        this.family = family;
        this.style = style;
    }

    public static Typeface create(Typeface family, int style) {
        return new Typeface(family == null ? DEFAULT.family : family.family, style);
    }

    public static Typeface create(String familyName, int style) {
        return new Typeface(familyName == null || familyName.isEmpty() ? DEFAULT.family : familyName, style);
    }

    public static Typeface defaultFromStyle(int style) {
        return new Typeface(DEFAULT.family, style);
    }

    public int getStyle() {
        return style;
    }

    public final boolean isBold() {
        return (style & BOLD) != 0;
    }

    public final boolean isItalic() {
        return (style & ITALIC) != 0;
    }

    /** Java2D 字体族名（供 {@link Paint} 使用）。 */
    String family() {
        return family;
    }
}
