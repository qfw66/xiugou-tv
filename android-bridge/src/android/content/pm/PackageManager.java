package android.content.pm;

/**
 * 桌面端 {@code PackageManager}：**「包未安装」语义**，不伪造签名。
 *
 * <p>载荷（{@code InitOrigin.init} 等）会取 {@code getPackageInfo(pkg, GET_SIGNATURES)}
 * 再读 {@code signatures[0].toByteArray()} 做设备指纹。桌面端没有安装 APK，
 * 诚实的回答是「查不到这个包」——抛 {@link NameNotFoundException}，让载荷走它自己
 * 已经写好的 catch 分支；伪造一份假证书反而会让签名校验类站点算出错误的 signature。
 *
 * <p>本类只实现载荷真实调用到的成员（成员级引用见 test/repro/_refs_android_content_pm.txt）。
 */
public class PackageManager {

    public static final int GET_ACTIVITIES = 0x00000001;
    public static final int GET_META_DATA = 0x00000080;
    public static final int GET_SIGNATURES = 0x00000040;
    public static final int GET_SIGNING_CERTIFICATES = 0x08000000;
    public static final int GET_PERMISSIONS = 0x00001000;
    public static final int GET_SERVICES = 0x00000004;
    public static final int GET_PROVIDERS = 0x00000008;
    public static final int GET_RECEIVERS = 0x00000002;
    public static final int MATCH_DEFAULT_ONLY = 0x00010000;

    public PackageInfo getPackageInfo(String packageName, int flags) throws NameNotFoundException {
        throw new NameNotFoundException(packageName);
    }

    public PackageInfo getPackageInfo(String packageName, PackageInfoFlags flags)
            throws NameNotFoundException {
        throw new NameNotFoundException(packageName);
    }

    public ApplicationInfo getApplicationInfo(String packageName, int flags)
            throws NameNotFoundException {
        throw new NameNotFoundException(packageName);
    }

    public java.util.List<ApplicationInfo> getInstalledApplications(int flags) {
        return new java.util.ArrayList<>();
    }

    public java.util.List<PackageInfo> getInstalledPackages(int flags) {
        return new java.util.ArrayList<>();
    }

    public CharSequence getApplicationLabel(ApplicationInfo info) {
        return info == null ? "" : info.packageName;
    }

    public android.content.Intent getLaunchIntentForPackage(String packageName) {
        return null;
    }

    public boolean hasSystemFeature(String name) {
        return false;
    }

    public ProviderInfo resolveContentProvider(String name, int flags) {
        return null;
    }

    public boolean isPackageAvailable(String packageName) {
        return false;
    }

    /** Android 原名即 {@code PackageManager.NameNotFoundException}，继承 Exception。 */
    public static class NameNotFoundException extends Exception {
        private static final long serialVersionUID = 1L;

        public NameNotFoundException() {
            super();
        }

        public NameNotFoundException(String name) {
            super(name == null ? "" : name);
        }
    }

    /** Android 13+ 的 flags 值类型；仅为兼容少见调用点。 */
    public static final class PackageInfoFlags {
        private PackageInfoFlags() {
        }
    }
}
