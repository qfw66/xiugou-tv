package android.content.pm;

import android.graphics.drawable.Drawable;

/**
 * android.content.pm.PackageItemInfo 桩。
 *
 * <p>{@link ApplicationInfo} 在 Android 里就继承本类，载荷会对它调
 * {@code loadLabel(pm)} / {@code loadIcon(pm)}；桌面端没有资源系统，如实返回
 * 包名/空图标。
 */
public class PackageItemInfo {

    public String name = "";
    public String packageName = "";
    public int labelRes;
    public CharSequence nonLocalizedLabel;
    public int icon;

    public PackageItemInfo() {
    }

    public CharSequence loadLabel(PackageManager pm) {
        if (nonLocalizedLabel != null) return nonLocalizedLabel;
        return name == null ? "" : name;
    }

    public Drawable loadIcon(PackageManager pm) {
        return null;
    }

    public android.content.res.XmlResourceParser loadXmlMetaData(PackageManager pm, String name) {
        return null;
    }
}
