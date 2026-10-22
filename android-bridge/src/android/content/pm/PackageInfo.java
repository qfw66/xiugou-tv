package android.content.pm;

/** android.content.pm.PackageInfo 桩（只保留载荷读写的字段）。 */
public class PackageInfo {

    public String packageName = "";
    public String versionName = "";
    public int versionCode;
    public String sharedUserId;

    public ApplicationInfo applicationInfo;
    public Signature[] signatures;
    public String[] requestedPermissions;

    public long firstInstallTime;
    public long lastUpdateTime;

    public PackageInfo() {
    }
}
