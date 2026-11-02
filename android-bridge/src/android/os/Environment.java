package android.os;

import java.io.File;

/**
 * companion android shim: android.os.Environment
 *
 * 手机端网盘系 spider（夸克 QuarkApi、Cloud 系等）用它取外部存储/缓存目录；
 * 桌面端映射到 ~/.xiugou_tv_companion/sdcard（外部存储）与 ~/.xiugou_tv_companion/data（/data），
 * 保证可读写且跨会话稳定；只有下载缓存目录仍放系统临时目录。
 *
 * 触发场景：dongli-spider.jar 的 Wogg.init → QuarkApi.getCache → NoClassDefFoundError.
 */
public class Environment {

    public static final String MEDIA_MOUNTED = "mounted";
    public static final String MEDIA_MOUNTED_READ_ONLY = "mounted_ro";
    public static final String MEDIA_REMOVED = "removed";
    public static final String MEDIA_UNMOUNTED = "unmounted";

    public static final String DIRECTORY_MUSIC = "Music";
    public static final String DIRECTORY_PODCASTS = "Podcasts";
    public static final String DIRECTORY_RINGTONES = "Ringtones";
    public static final String DIRECTORY_ALARMS = "Alarms";
    public static final String DIRECTORY_NOTIFICATIONS = "Notifications";
    public static final String DIRECTORY_PICTURES = "Pictures";
    public static final String DIRECTORY_MOVIES = "Movies";
    public static final String DIRECTORY_DOWNLOADS = "Download";
    public static final String DIRECTORY_DCIM = "DCIM";
    public static final String DIRECTORY_DOCUMENTS = "Documents";

    private static File storageRoot() {
        File root = new File(new File(System.getProperty("user.home", "."), ".xiugou_tv_companion"), "sdcard");
        if (!root.exists()) root.mkdirs();
        return root;
    }

    public static File getExternalStorageDirectory() {
        return storageRoot();
    }

    public static File getExternalStoragePublicDirectory(String type) {
        File dir = new File(storageRoot(), type == null ? "" : type);
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static String getExternalStorageState() {
        return MEDIA_MOUNTED;
    }

    public static boolean isExternalStorageRemovable() {
        return false;
    }

    public static boolean isExternalStorageEmulated() {
        return true;
    }

    /**
     * Android 的 /data。原先映射到系统临时目录：载荷若在此存登录态，会被系统清理掉。
     * 改为站源服务目录下的 data/（持久，「重置所有设置」会清掉）。
     */
    public static File getDataDirectory() {
        File dir = new File(new File(System.getProperty("user.home", "."), ".xiugou_tv_companion"), "data");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File getDownloadCacheDirectory() {
        File dir = new File(System.getProperty("java.io.tmpdir"), "xiugou_tv_download_cache");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    /** 桌面端没有分区存储限制，视为已获「所有文件访问」权限。 */
    public static boolean isExternalStorageManager() {
        return true;
    }
}
