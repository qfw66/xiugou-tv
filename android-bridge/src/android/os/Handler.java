package android.os;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Minimal android.os.Handler stub。
 *
 * <p>桌面端没有 Android 主线程消息循环，因此这里用一条守护调度线程近似：
 * <ul>
 *   <li>{@link #post(Runnable)} / {@link #postDelayed(Runnable, long)} 默认**同步**执行
 *       （保持既有行为，避免给载荷引入新的并发时序），但带重入保护；</li>
 *   <li>同一个 runnable 在自己内部再次投递自己时，改为异步执行 —— 否则直接爆栈：
 *       实测 wexguard 载荷的 {@code InitOrigin.post} 在 runnable 里再次 postDelayed 自己，
 *       纯同步实现下 100% {@code StackOverflowError}；</li>
 *   <li>{@link #sendEmptyMessageDelayed(int, long)} 异步投递（消息不构成递归）。</li>
 * </ul>
 *
 * <p>已知限制：{@link #removeCallbacks(Runnable)} 无法取消已投递的延迟任务
 * （未保存 Future）——载荷侧极少依赖该语义，真需要时再补。
 */
public class Handler {

    /** 延迟投递用的单线程调度器（顺序执行，避免并发打乱载荷预期）。 */
    private static final ScheduledExecutorService SCHEDULER = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "android-handler");
        t.setDaemon(true);
        return t;
    });

    /** 当前线程正在执行的 runnable（按引用比较），用于识别「自我重投」。 */
    private static final ThreadLocal<Set<Runnable>> RUNNING =
            ThreadLocal.withInitial(() -> Collections.newSetFromMap(new IdentityHashMap<>()));

    private final Callback callback;

    public Handler() {
        this.callback = null;
    }

    public Handler(Looper looper) {
        this.callback = null;
    }

    public Handler(Callback callback) {
        this.callback = callback;
    }

    public Handler(Looper looper, Callback callback) {
        this.callback = callback;
    }

    public boolean post(Runnable r) {
        if (r == null) return false;
        Set<Runnable> running = RUNNING.get();
        if (running.contains(r)) {
            // 同一个 runnable 在自己内部又 post 自己：改走异步，切断递归
            SCHEDULER.schedule(r, 1, TimeUnit.MILLISECONDS);
            return true;
        }
        running.add(r);
        try {
            r.run();
        } finally {
            running.remove(r);
        }
        return true;
    }

    public boolean postDelayed(Runnable r, long delayMillis) {
        if (r == null) return false;
        Set<Runnable> running = RUNNING.get();
        if (running.contains(r)) {
            // 自我重投（实测 wexguard 的 InitOrigin.post 就是这种）：改异步，切断递归
            SCHEDULER.schedule(r, Math.max(1, delayMillis), TimeUnit.MILLISECONDS);
            return true;
        }
        // 其余情况保持**同步**执行：与既有行为一致，避免给载荷引入新的并发时序
        running.add(r);
        try {
            r.run();
        } finally {
            running.remove(r);
        }
        return true;
    }

    public boolean postAtFrontOfQueue(Runnable r) {
        return post(r);
    }

    public void removeCallbacks(Runnable r) {
    }

    public void removeCallbacksAndMessages(Object token) {
    }

    public boolean sendMessage(Message msg) {
        if (msg != null) dispatchMessage(msg);
        return true;
    }

    public boolean sendEmptyMessage(int what) {
        Message msg = Message.obtain();
        msg.what = what;
        return sendMessage(msg);
    }

    public boolean sendEmptyMessageDelayed(int what, long delayMillis) {
        Message msg = Message.obtain();
        msg.what = what;
        msg.target = this;
        SCHEDULER.schedule(() -> dispatchMessage(msg), Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
        return true;
    }

    public Message obtainMessage() {
        Message msg = Message.obtain();
        msg.target = this;
        return msg;
    }

    public Message obtainMessage(int what) {
        Message msg = obtainMessage();
        msg.what = what;
        return msg;
    }

    public Message obtainMessage(int what, Object obj) {
        Message msg = obtainMessage(what);
        msg.obj = obj;
        return msg;
    }

    public Message obtainMessage(int what, int arg1, int arg2) {
        Message msg = obtainMessage(what);
        msg.arg1 = arg1;
        msg.arg2 = arg2;
        return msg;
    }

    /** 与 {@link #sendEmptyMessageDelayed} 一致：延迟消息异步投递。 */
    public boolean sendMessageDelayed(Message msg, long delayMillis) {
        if (msg == null) return false;
        msg.target = this;
        SCHEDULER.schedule(() -> dispatchMessage(msg), Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
        return true;
    }

    /** 已投递的延迟消息无法追踪（见类注释的已知限制），按「没有待处理消息」回答。 */
    public boolean hasMessages(int what) {
        return false;
    }

    public void dispatchMessage(Message msg) {
        if (msg.callback != null) {
            msg.callback.run();
        } else if (callback != null) {
            callback.handleMessage(msg);
        } else {
            handleMessage(msg);
        }
    }

    public void handleMessage(Message msg) {
    }

    public Looper getLooper() {
        return Looper.getMainLooper();
    }

    public interface Callback {
        boolean handleMessage(Message msg);
    }
}
