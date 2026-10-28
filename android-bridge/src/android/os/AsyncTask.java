package android.os;

import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * android.os.AsyncTask 的桌面实现，语义与 Android 一致：
 * {@link #onPreExecute()} 在调用线程，{@link #doInBackground} 在线程池，
 * {@link #onPostExecute} / {@link #onCancelled} 在后台任务结束后执行，{@link #get()} 可阻塞取结果。
 *
 * <p>桌面端没有主线程消息循环，结束回调与 {@link #onProgressUpdate} 直接在工作线程执行。
 * 载荷的网盘链接校验用它并发探测分享链接，然后 {@code get()} 等结果。
 */
public abstract class AsyncTask<Params, Progress, Result> {

    public enum Status {
        PENDING,
        RUNNING,
        FINISHED
    }

    private static final ExecutorService POOL = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r, "AsyncTask");
        t.setDaemon(true);
        return t;
    });

    /** Android 公开的两个执行器：并行池与串行队列。 */
    public static final Executor THREAD_POOL_EXECUTOR = POOL;
    public static final Executor SERIAL_EXECUTOR = new SerialExecutor();

    private volatile Status status = Status.PENDING;
    private final AtomicBoolean cancelled = new AtomicBoolean();
    private FutureTask<Result> future;

    public AsyncTask() {
    }

    protected abstract Result doInBackground(Params... params);

    protected void onPreExecute() {
    }

    protected void onPostExecute(Result result) {
    }

    protected void onProgressUpdate(Progress... values) {
    }

    protected void onCancelled(Result result) {
        onCancelled();
    }

    protected void onCancelled() {
    }

    @SafeVarargs
    public final AsyncTask<Params, Progress, Result> execute(Params... params) {
        return executeOnExecutor(SERIAL_EXECUTOR, params);
    }

    @SafeVarargs
    public final AsyncTask<Params, Progress, Result> executeOnExecutor(Executor exec, Params... params) {
        if (status != Status.PENDING) {
            throw new IllegalStateException(status == Status.RUNNING
                    ? "Cannot execute task: the task is already running."
                    : "Cannot execute task: the task has already been executed (a task can be executed only once)");
        }
        status = Status.RUNNING;
        onPreExecute();
        future = new FutureTask<>(() -> {
            Result result = null;
            try {
                result = doInBackground(params);
                return result;
            } finally {
                finish(result);
            }
        });
        exec.execute(future);
        return this;
    }

    public static void execute(Runnable runnable) {
        SERIAL_EXECUTOR.execute(runnable);
    }

    private void finish(Result result) {
        if (isCancelled()) onCancelled(result);
        else onPostExecute(result);
        status = Status.FINISHED;
    }

    @SafeVarargs
    protected final void publishProgress(Progress... values) {
        if (!isCancelled()) onProgressUpdate(values);
    }

    public final boolean cancel(boolean mayInterruptIfRunning) {
        cancelled.set(true);
        return future != null && future.cancel(mayInterruptIfRunning);
    }

    public final boolean isCancelled() {
        return cancelled.get();
    }

    public final Status getStatus() {
        return status;
    }

    public final Result get() throws InterruptedException, ExecutionException {
        if (future == null) throw new IllegalStateException("task not executed");
        return future.get();
    }

    public final Result get(long timeout, TimeUnit unit)
            throws InterruptedException, ExecutionException, TimeoutException {
        if (future == null) throw new IllegalStateException("task not executed");
        return future.get(timeout, unit);
    }

    /** 与 Android 一致：按提交顺序逐个执行，实际运行在共享线程池上。 */
    private static final class SerialExecutor implements Executor {
        private final java.util.ArrayDeque<Runnable> tasks = new java.util.ArrayDeque<>();
        private Runnable active;

        @Override
        public synchronized void execute(Runnable r) {
            tasks.offer(() -> {
                try {
                    r.run();
                } finally {
                    scheduleNext();
                }
            });
            if (active == null) scheduleNext();
        }

        private synchronized void scheduleNext() {
            active = tasks.poll();
            if (active != null) POOL.execute(active);
        }
    }
}
