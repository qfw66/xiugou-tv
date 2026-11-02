package android.os;

/**
 * Desktop stand-in for the Android main looper.
 *
 * <p>Payloads use {@code Looper.myLooper() == Looper.getMainLooper()} to decide whether they may block
 * (e.g. waiting for login credentials). Spider RPCs run on worker threads, as on Android, so only code
 * dispatched through the main {@link Handler} counts as the main thread here.
 */
public class Looper {

    private static final Looper MAIN = new Looper();
    /** Identity of the main thread as seen from a worker; never started. */
    private static final Thread MAIN_THREAD = new Thread("android-main");
    /** Nesting depth of main-looper work executing synchronously on the current thread. */
    private static final ThreadLocal<int[]> MAIN_DEPTH = ThreadLocal.withInitial(() -> new int[1]);

    public static Looper getMainLooper() {
        return MAIN;
    }

    /** Android returns null on threads without a looper; worker threads have none. */
    public static Looper myLooper() {
        return isMainThread() ? MAIN : null;
    }

    public static void prepare() {
    }

    public static void loop() {
    }

    public void quit() {
    }

    public void quitSafely() {
    }

    public Thread getThread() {
        return isMainThread() ? Thread.currentThread() : MAIN_THREAD;
    }

    public boolean isCurrentThread() {
        return isMainThread();
    }

    static boolean isMainThread() {
        return MAIN_DEPTH.get()[0] > 0 || Handler.isSchedulerThread();
    }

    static void enterMain() {
        MAIN_DEPTH.get()[0]++;
    }

    static void exitMain() {
        MAIN_DEPTH.get()[0]--;
    }
}
