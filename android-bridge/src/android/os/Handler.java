package android.os;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
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
 * <p>所有异步投递都登记在 {@link #PENDING}：{@link #removeCallbacks}、{@link #hasMessages}
 * 才有真实语义，换配置时 {@link #cancelAll(ClassLoader)} 才能停掉旧载荷的心跳——
 * 否则这类自我重投的任务永远循环，并把旧类加载器（连同其元空间）永久钉住。
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

    /** 一条尚未执行的异步投递。 */
    private static final class Pending {
        final Handler handler;
        final Runnable runnable;   // runnable 投递；消息投递为 null
        final Message message;     // 消息投递；runnable 投递为 null
        final ClassLoader owner;   // 投递者所属的类加载器（按它整批取消）
        volatile ScheduledFuture<?> future;

        Pending(Handler handler, Runnable runnable, Message message, ClassLoader owner) {
            this.handler = handler;
            this.runnable = runnable;
            this.message = message;
            this.owner = owner;
        }

        void cancel() {
            ScheduledFuture<?> f = future;
            if (f != null) f.cancel(false);
        }
    }

    /** 全部未执行的异步投递。App.post 每次 new 一个 Handler，所以登记必须是全局的。 */
    private static final Set<Pending> PENDING = ConcurrentHashMap.newKeySet();

    /**
     * 已退役（换配置被淘汰）的类加载器：之后它再发起的异步投递一律丢弃。
     * 防止 cancelAll 那一刻正在执行的心跳任务跑完后把自己重新投递回来。弱引用，不延长 loader 寿命。
     */
    private static final Set<ClassLoader> RETIRED =
            Collections.synchronizedSet(Collections.newSetFromMap(new java.util.WeakHashMap<>()));

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
            scheduleRunnable(r, 1);
            return true;
        }
        runMarked(r);
        return true;
    }

    public boolean postDelayed(Runnable r, long delayMillis) {
        if (r == null) return false;
        Set<Runnable> running = RUNNING.get();
        if (running.contains(r)) {
            // 自我重投（实测 wexguard 的 InitOrigin.post 就是这种）：改异步，切断递归
            scheduleRunnable(r, Math.max(1, delayMillis));
            return true;
        }
        // 其余情况保持**同步**执行：与既有行为一致，避免给载荷引入新的并发时序
        runMarked(r);
        return true;
    }

    public boolean postAtFrontOfQueue(Runnable r) {
        return post(r);
    }

    /** 取消该 runnable 尚未执行的全部异步投递（与 App.post 的「先 remove 再 post」防抖语义一致）。 */
    public void removeCallbacks(Runnable r) {
        if (r == null) return;
        cancelWhere(p -> p.runnable == r);
    }

    /** token 为 null 时取消本 handler 的全部投递；否则只取消 {@code msg.obj == token} 的消息。 */
    public void removeCallbacksAndMessages(Object token) {
        cancelWhere(p -> p.handler == this && (token == null || (p.message != null && p.message.obj == token)));
    }

    public void removeMessages(int what) {
        cancelWhere(p -> p.handler == this && p.message != null && p.message.what == what);
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
        return sendMessageDelayed(msg, delayMillis);
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
        Object owner = msg.callback != null ? msg.callback : (callback != null ? callback : this);
        Pending p = new Pending(this, null, msg, owner.getClass().getClassLoader());
        schedule(p, () -> dispatchMessage(msg), Math.max(0, delayMillis));
        return true;
    }

    /** 本 handler 是否还有该 what 的消息未执行。 */
    public boolean hasMessages(int what) {
        for (Pending p : PENDING) {
            if (p.handler == this && p.message != null && p.message.what == what) return true;
        }
        return false;
    }

    public void dispatchMessage(Message msg) {
        Looper.enterMain();
        try {
            if (msg.callback != null) {
                msg.callback.run();
            } else if (callback != null) {
                callback.handleMessage(msg);
            } else {
                handleMessage(msg);
            }
        } finally {
            Looper.exitMain();
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

    // ------------------------------------------------------------------ 换配置清理

    /**
     * 取消某个类加载器投递的全部未执行任务（换配置时由加载器在关闭旧 loader 前调用）。
     *
     * @return 取消的条数
     */
    public static int cancelAll(ClassLoader owner) {
        if (owner == null) return 0;
        RETIRED.add(owner);
        return cancelWhere(p -> p.owner == owner);
    }

    /** 当前未执行的异步投递条数（诊断 / 测试用）。 */
    public static int pendingCount() {
        return PENDING.size();
    }

    // ------------------------------------------------------------------ 实现

    private void scheduleRunnable(Runnable r, long delayMillis) {
        Pending p = new Pending(this, r, null, r.getClass().getClassLoader());
        // 后台执行时同样标记为「正在执行」：其内部的自我重投才会按延时异步进行，
        // 而不是在调度线程上先同步再跑一遍（否则每个周期执行两次、第二次没有延时）
        schedule(p, () -> runMarked(r), delayMillis);
    }

    private static void schedule(Pending p, Runnable body, long delayMillis) {
        if (p.owner != null && RETIRED.contains(p.owner)) return; // 旧载荷的重投，丢弃
        PENDING.add(p);
        p.future = SCHEDULER.schedule(() -> {
            PENDING.remove(p);
            try {
                body.run();
            } catch (Throwable t) {
                // ScheduledFuture 无人 get，异常会被静默吞掉：至少留一条日志便于排查载荷
                System.err.println("[android.os.Handler] 异步任务异常: " + t);
            }
        }, delayMillis, TimeUnit.MILLISECONDS);
    }

    private static void runMarked(Runnable r) {
        Set<Runnable> running = RUNNING.get();
        running.add(r);
        Looper.enterMain();
        try {
            r.run();
        } finally {
            Looper.exitMain();
            running.remove(r);
        }
    }

    static boolean isSchedulerThread() {
        return "android-handler".equals(Thread.currentThread().getName());
    }

    private static int cancelWhere(java.util.function.Predicate<Pending> match) {
        int n = 0;
        for (Iterator<Pending> it = PENDING.iterator(); it.hasNext(); ) {
            Pending p = it.next();
            if (match.test(p)) {
                p.cancel();
                it.remove();
                n++;
            }
        }
        return n;
    }
}
