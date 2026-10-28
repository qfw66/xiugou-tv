package android.content.res;

import android.util.DisplayMetrics;

/**
 * Minimal android.content.res.Resources stub.
 * 载荷（merge.ME.q 等）用它取 DisplayMetrics 做 dp→px 换算。
 */
public class Resources {

    private static final DisplayMetrics METRICS = new DisplayMetrics();

    public DisplayMetrics getDisplayMetrics() {
        return METRICS;
    }

    public String getString(int id) {
        String system = SYSTEM_STRINGS.get(id);
        return system != null ? system : "";
    }

    /**
     * 载荷弹窗常用的 {@code android.R.string.*}（资源号是 AOSP 公开常量），按中文系统的文案返回；
     * 否则 {@code setPositiveButton(android.R.string.ok, ...)} 的按钮会没有文字。
     */
    private static final java.util.Map<Integer, String> SYSTEM_STRINGS = java.util.Map.of(
            17039360, "取消",   // cancel
            17039361, "复制",   // copy
            17039369, "否",     // no
            17039370, "确定",   // ok
            17039371, "粘贴",   // paste
            17039373, "全选",   // selectAll
            17039379, "是",     // yes
            17039380, "注意");  // dialog_alert_title

    public String getString(int id, Object... formatArgs) {
        return "";
    }

    public int getIdentifier(String name, String defType, String defPackage) {
        return 0;
    }

    public int getDimensionPixelSize(int id) {
        return 0;
    }

    public float getDimension(int id) {
        return 0f;
    }

    private static final Configuration CONFIGURATION = new Configuration();

    public Configuration getConfiguration() {
        return CONFIGURATION;
    }

    public ColorStateList getColorStateList(int id) {
        return ColorStateList.valueOf(0xFF000000);
    }

    public int getColor(int id) {
        return 0xFF000000;
    }

    public android.graphics.drawable.Drawable getDrawable(int id) {
        return null;
    }

    public String getResourceEntryName(int id) {
        throw new NotFoundException("Unable to find resource ID #0x" + Integer.toHexString(id));
    }

    public static class NotFoundException extends RuntimeException {
        public NotFoundException() {
        }

        public NotFoundException(String name) {
            super(name);
        }
    }
}
