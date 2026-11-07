package android.os;

/**
 * 桌面版 HandlerThread：桌面的 Handler 不区分线程（见 Handler），这里的 Looper 只是占位，
 * getLooper() 立即可用，不需要真正跑消息循环。
 */
public class HandlerThread extends Thread {
    private final int priority;

    public HandlerThread(String name) {
        this(name, Process.THREAD_PRIORITY_DEFAULT);
    }

    public HandlerThread(String name, int priority) {
        super(name);
        this.priority = priority;
        setDaemon(true);
    }

    @Override
    public void run() {
    }

    public Looper getLooper() {
        return Looper.getMainLooper();
    }

    public boolean quit() {
        return true;
    }

    public boolean quitSafely() {
        return true;
    }

    public int getThreadId() {
        return (int) getId();
    }
}
