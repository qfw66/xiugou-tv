package android.graphics;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * android.graphics.Color：ARGB 整数颜色工具，语义与 Android 一致（{@code parseColor} 支持
 * {@code #RRGGBB}、{@code #AARRGGBB} 与常用颜色名，其余抛 {@link IllegalArgumentException}）。
 */
public class Color {

    public static final int BLACK = 0xFF000000;
    public static final int DKGRAY = 0xFF444444;
    public static final int GRAY = 0xFF888888;
    public static final int LTGRAY = 0xFFCCCCCC;
    public static final int WHITE = 0xFFFFFFFF;
    public static final int RED = 0xFFFF0000;
    public static final int GREEN = 0xFF00FF00;
    public static final int BLUE = 0xFF0000FF;
    public static final int YELLOW = 0xFFFFFF00;
    public static final int CYAN = 0xFF00FFFF;
    public static final int MAGENTA = 0xFFFF00FF;
    public static final int TRANSPARENT = 0;

    private static final Map<String, Integer> NAMES = new HashMap<>();

    static {
        NAMES.put("black", BLACK);
        NAMES.put("darkgray", DKGRAY);
        NAMES.put("darkgrey", DKGRAY);
        NAMES.put("gray", GRAY);
        NAMES.put("grey", GRAY);
        NAMES.put("lightgray", LTGRAY);
        NAMES.put("lightgrey", LTGRAY);
        NAMES.put("white", WHITE);
        NAMES.put("red", RED);
        NAMES.put("green", GREEN);
        NAMES.put("blue", BLUE);
        NAMES.put("yellow", YELLOW);
        NAMES.put("cyan", CYAN);
        NAMES.put("magenta", MAGENTA);
        NAMES.put("aqua", 0xFF00FFFF);
        NAMES.put("fuchsia", 0xFFFF00FF);
        NAMES.put("lime", 0xFF00FF00);
        NAMES.put("maroon", 0xFF800000);
        NAMES.put("navy", 0xFF000080);
        NAMES.put("olive", 0xFF808000);
        NAMES.put("purple", 0xFF800080);
        NAMES.put("silver", 0xFFC0C0C0);
        NAMES.put("teal", 0xFF008080);
    }

    public static int parseColor(String colorString) {
        if (colorString != null && colorString.length() > 1 && colorString.charAt(0) == '#') {
            long color = Long.parseLong(colorString.substring(1), 16);
            if (colorString.length() == 7) {
                color |= 0x00000000FF000000L;
            } else if (colorString.length() != 9) {
                throw new IllegalArgumentException("Unknown color");
            }
            return (int) color;
        }
        Integer named = colorString == null ? null : NAMES.get(colorString.toLowerCase(Locale.ROOT));
        if (named != null) return named;
        throw new IllegalArgumentException("Unknown color");
    }

    public static int argb(int alpha, int red, int green, int blue) {
        return (alpha << 24) | (red << 16) | (green << 8) | blue;
    }

    public static int rgb(int red, int green, int blue) {
        return 0xFF000000 | (red << 16) | (green << 8) | blue;
    }

    public static int alpha(int color) {
        return color >>> 24;
    }

    public static int red(int color) {
        return (color >> 16) & 0xFF;
    }

    public static int green(int color) {
        return (color >> 8) & 0xFF;
    }

    public static int blue(int color) {
        return color & 0xFF;
    }
    /** RGB 转 HSV（hsv[0] 色相 0..360，hsv[1] 饱和度、hsv[2] 明度 0..1），与 AOSP 结果一致。 */
    public static void RGBToHSV(int red, int green, int blue, float[] hsv) {
        if (hsv == null || hsv.length < 3) throw new IllegalArgumentException("3 components required for hsv");
        float r = red / 255f;
        float g = green / 255f;
        float b = blue / 255f;
        float max = Math.max(r, Math.max(g, b));
        float min = Math.min(r, Math.min(g, b));
        float delta = max - min;
        float h;
        if (delta == 0f) {
            h = 0f;
        } else if (max == r) {
            h = 60f * (((g - b) / delta) % 6f);
        } else if (max == g) {
            h = 60f * (((b - r) / delta) + 2f);
        } else {
            h = 60f * (((r - g) / delta) + 4f);
        }
        if (h < 0f) h += 360f;
        hsv[0] = h;
        hsv[1] = max == 0f ? 0f : delta / max;
        hsv[2] = max;
    }

    public static void colorToHSV(int color, float[] hsv) {
        RGBToHSV(red(color), green(color), blue(color), hsv);
    }

    public static int HSVToColor(float[] hsv) {
        return HSVToColor(0xFF, hsv);
    }

    public static int HSVToColor(int alpha, float[] hsv) {
        if (hsv == null || hsv.length < 3) throw new IllegalArgumentException("3 components required for hsv");
        float h = ((hsv[0] % 360f) + 360f) % 360f;
        float s = Math.max(0f, Math.min(1f, hsv[1]));
        float v = Math.max(0f, Math.min(1f, hsv[2]));
        float c = v * s;
        float x = c * (1 - Math.abs((h / 60f) % 2f - 1));
        float m = v - c;
        float r;
        float g;
        float b;
        if (h < 60) {
            r = c; g = x; b = 0;
        } else if (h < 120) {
            r = x; g = c; b = 0;
        } else if (h < 180) {
            r = 0; g = c; b = x;
        } else if (h < 240) {
            r = 0; g = x; b = c;
        } else if (h < 300) {
            r = x; g = 0; b = c;
        } else {
            r = c; g = 0; b = x;
        }
        return argb(alpha, Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255));
    }
}
