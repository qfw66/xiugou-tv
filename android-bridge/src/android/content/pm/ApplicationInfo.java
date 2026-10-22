package android.content.pm;

/**
 * 桌面端的 {@code ApplicationInfo} 桩。
 *
 * <p>加固壳（wexguard 的 {@code LoadNiMa} 加载器、ftyguard 的签名模块）在初始化时会读
 * {@code context.getApplicationInfo().sourceDir / nativeLibraryDir / packageName}
 * 来定位自己的 so 与资源。缺这个类会抛
 * {@code NoSuchMethodError: android.content.pm.ApplicationInfo Context.getApplicationInfo()}
 * 并在多个后台线程里刷屏，壳的后续步骤全部中断。
 *
 * <p>字段与 Android 保持一致（都是 public），取值指向桌面端的真实路径，
 * 让壳至少能完成"文件定位"这一步。
 */
public class ApplicationInfo extends PackageItemInfo {

    public String processName = "com.fongmi.android.tv";

    /** APK 路径；桌面端用 jar 的位置兜底。 */
    public String sourceDir = "";

    /** 数据目录。 */
    public String dataDir = "";

    /** 原生库目录。桌面端没有可用的 ARM so，指向一个空目录即可。 */
    public String nativeLibraryDir = "";

    public String publicSourceDir = "";
    public String scanSourceDir = "";
    public String[] splitSourceDirs;
    public String[] splitPublicSourceDirs;

    public int flags = 0;
    public int targetSdkVersion = 30;
    public int minSdkVersion = 21;
    public int uid = 10000;
    public String[] sharedLibraryFiles;

    public ApplicationInfo() {
        packageName = "com.fongmi.android.tv";
        name = packageName;
        String home = System.getProperty("user.home", ".");
        dataDir = home + "/.xiugou_tv_companion";
        nativeLibraryDir = dataDir + "/lib";
        sourceDir = dataDir;
        publicSourceDir = dataDir;
        scanSourceDir = dataDir;
    }

    public boolean isProfileableByShell() {
        return false;
    }

    public int describeContents() {
        return 0;
    }
}
