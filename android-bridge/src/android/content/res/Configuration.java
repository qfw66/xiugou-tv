package android.content.res;

/**
 * android.content.res.Configuration：桌面端固定报告「电视 + 横屏 + 浅色」，与 FongMi 电视版宿主一致。
 */
public class Configuration {

    public static final int ORIENTATION_PORTRAIT = 1;
    public static final int ORIENTATION_LANDSCAPE = 2;
    public static final int UI_MODE_TYPE_MASK = 0x0f;
    public static final int UI_MODE_TYPE_NORMAL = 0x01;
    public static final int UI_MODE_TYPE_TELEVISION = 0x04;
    public static final int UI_MODE_NIGHT_MASK = 0x30;
    public static final int UI_MODE_NIGHT_NO = 0x10;
    public static final int UI_MODE_NIGHT_YES = 0x20;

    public int orientation = ORIENTATION_LANDSCAPE;
    public static final int SCREENLAYOUT_SIZE_MASK = 0x0f;
    public static final int SCREENLAYOUT_SIZE_NORMAL = 0x02;
    public static final int SCREENLAYOUT_SIZE_LARGE = 0x03;
    public static final int SCREENLAYOUT_SIZE_XLARGE = 0x04;
    public static final int SCREENLAYOUT_LONG_YES = 0x20;

    /** 电视按超大屏、长屏报告。 */
    public int screenLayout = SCREENLAYOUT_SIZE_XLARGE | SCREENLAYOUT_LONG_YES;
    public int smallestScreenWidthDp = 1080;
    public int uiMode = UI_MODE_TYPE_TELEVISION | UI_MODE_NIGHT_NO;
    public int screenWidthDp = 1920;
    public int screenHeightDp = 1080;
    public int densityDpi = 160;
    public float fontScale = 1.0f;
}
