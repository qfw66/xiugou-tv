package android.os;

/**
 * Minimal android.os.Build stub.
 * SDK_INT 取 30（Android 11）：让 spider 走现代分支，避免旧版本兼容路径。
 */
public class Build {

    public static class VERSION {
        public static final int SDK_INT = 30;
        public static final String SDK = "30";
        public static final String RELEASE = "11";
        public static final String CODENAME = "REL";
        public static final String INCREMENTAL = "1";
    }

    public static class VERSION_CODES {
        public static final int LOLLIPOP = 21;
        public static final int M = 23;
        public static final int N = 24;
        public static final int O = 26;
        public static final int P = 28;
        public static final int Q = 29;
        public static final int R = 30;
    }

    public static final String MANUFACTURER = "fongmi";
    public static final String BRAND = "fongmi";
    public static final String MODEL = "xiugou-tv";
    public static final String DEVICE = "desktop";
    public static final String PRODUCT = "fongmi_desktop";
    public static final String HARDWARE = "desktop";
    public static final String FINGERPRINT = "fongmi/desktop/desktop:11/1:user/release-keys";
    public static final String ID = "RP1A.200720.009";

    /** 手机端网盘系 spider（夸克等）解析路径需要；缺失会抛 NoSuchFieldError。 */
    public static final String[] SUPPORTED_ABIS = {"arm64-v8a", "armeabi-v7a", "armeabi"};
    public static final String[] SUPPORTED_32_BIT_ABIS = {"armeabi-v7a", "armeabi"};
    public static final String[] SUPPORTED_64_BIT_ABIS = {"arm64-v8a"};
    public static final String CPU_ABI = "arm64-v8a";
    public static final String CPU_ABI2 = "armeabi-v7a";

    public static final String BOARD = "desktop";
    public static final String DISPLAY = ID;
    public static final String HOST = "desktop";
    public static final String TAGS = "release-keys";
    public static final String TYPE = "user";
    public static final String USER = "desktop";
    public static final String BOOTLOADER = "unknown";
    public static final String RADIO = "unknown";

    /** 部分站点（Appgz 等）读取设备序列号。 */
    public static final String SERIAL = "fongmi-desktop-0001";
}
