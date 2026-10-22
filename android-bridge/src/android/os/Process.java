package android.os;

/**
 * android.os.Process 桩。
 *
 * <p>载荷用它拼缓存文件名/日志前缀（{@code myPid()}）。桌面端 pid 取真实 JVM pid，
 * 保持多实例之间互不冲突。
 */
public class Process {

    public static final int SYSTEM_UID = 1000;
    public static final int THREAD_PRIORITY_DEFAULT = 0;
    public static final int THREAD_PRIORITY_BACKGROUND = 10;

    private static final int PID = resolvePid();

    private static int resolvePid() {
        try {
            String name = java.lang.management.ManagementFactory.getRuntimeMXBean().getName();
            int at = name.indexOf('@');
            return Integer.parseInt(at > 0 ? name.substring(0, at) : name);
        } catch (Throwable t) {
            return 1;
        }
    }

    public static int myPid() {
        return PID;
    }

    public static int myTid() {
        return PID;
    }

    public static int myUid() {
        return 10000;
    }

    public static void setThreadPriority(int priority) {
    }

    public static void killProcess(int pid) {
    }

    public static void sendSignal(int pid, int signal) {
    }
}
