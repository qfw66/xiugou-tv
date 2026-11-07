package android.app;

/** 只给内存档位类查询用：按 JVM 最大堆折算（MB），与安卓 TV 常见 256/512 相当。 */
public class ActivityManager {

    public int getMemoryClass() {
        return (int) Math.max(64, Math.min(512, Runtime.getRuntime().maxMemory() / (1024 * 1024)));
    }

    public int getLargeMemoryClass() {
        return getMemoryClass();
    }

    public boolean isLowRamDevice() {
        return false;
    }

    public static boolean isRunningInTestHarness() {
        return false;
    }
}
