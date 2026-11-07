package android.app;

/** 桌面端：与 {@link android.content.res.Configuration#uiMode} 一致，按电视上报界面模式。 */
public class UiModeManager {
    public static final int MODE_NIGHT_AUTO = 0;
    public static final int MODE_NIGHT_NO = 1;
    public static final int MODE_NIGHT_YES = 2;

    public int getCurrentModeType() {
        return android.content.res.Configuration.UI_MODE_TYPE_TELEVISION;
    }

    public int getNightMode() {
        return MODE_NIGHT_NO;
    }

    public void setNightMode(int mode) {
    }
}