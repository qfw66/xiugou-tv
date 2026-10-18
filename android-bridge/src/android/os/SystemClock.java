package android.os;

/**
 * companion android shim: android.os.SystemClock
 *
 * 手机端 spider（网盘/播放路径）用它做耗时统计与节流；桌面端用 System.nanoTime 的
 * 单调毫秒近似（elapsedRealtime 含休眠 / uptimeMillis 不含——桌面环境无需区分）。
 */
public class SystemClock {

    public static long elapsedRealtime() {
        return System.nanoTime() / 1_000_000L;
    }

    public static long uptimeMillis() {
        return System.nanoTime() / 1_000_000L;
    }

    public static long currentThreadTimeMillis() {
        return uptimeMillis();
    }

    public static long elapsedRealtimeNanos() {
        return System.nanoTime();
    }

    public static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public static boolean setCurrentTimeMillis(long millis) {
        return false;
    }
}
