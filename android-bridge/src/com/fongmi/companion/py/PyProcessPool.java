package com.fongmi.companion.py;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 同时存活的 Python 子进程上限（LRU）。
 *
 * <p>每个 py 站点一个 CPython 子进程（20~40 MB）；全站搜索会一次触达所有 py 站点，
 * 不设上限可拉起上百个。超过 {@link #MAX} 时淘汰最久未用且空闲的站点，它下次被用到时
 * 由 {@link PySpider} 惰性重启（不计入重启次数）。
 *
 * <p><b>锁顺序</b>：淘汰要拿被淘汰站点自己的锁，而登记发生在某个站点持有自己的锁时。
 * 若在登记线程上同步淘汰，两个站点同时启动会互相等对方的锁 → 死锁。
 * 所以登记只记账，淘汰交给专用线程异步执行，且执行时不持有本类的锁。
 */
final class PyProcessPool {

    static final int MAX = Math.max(1, Integer.getInteger("xiugou.py.maxProcesses", 8));

    /** 访问顺序的 LinkedHashMap：迭代从最久未用开始。 */
    private static final LinkedHashMap<PySpider, Boolean> LIVE = new LinkedHashMap<>(16, 0.75f, true);

    private static final ExecutorService EVICTOR = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "py-pool-evictor");
        t.setDaemon(true);
        return t;
    });

    private PyProcessPool() {
    }

    /** 新进程已拉起：记账，并异步检查是否超限。 */
    static void admitLater(PySpider spider) {
        synchronized (LIVE) {
            LIVE.put(spider, Boolean.TRUE);
        }
        EVICTOR.execute(PyProcessPool::evictOverflow);
    }

    /** 被使用：移到最近使用端。 */
    static void touch(PySpider spider) {
        synchronized (LIVE) {
            LIVE.put(spider, Boolean.TRUE);
        }
    }

    static void forget(PySpider spider) {
        synchronized (LIVE) {
            LIVE.remove(spider);
        }
    }

    /** 当前登记的存活站点数（诊断 / 测试用）。 */
    static int size() {
        synchronized (LIVE) {
            return LIVE.size();
        }
    }

    /** 等待已排队的淘汰执行完（测试用）。 */
    static void awaitIdle() throws Exception {
        EVICTOR.submit(() -> { }).get();
    }

    private static void evictOverflow() {
        List<PySpider> oldestFirst;
        synchronized (LIVE) {
            if (LIVE.size() <= MAX) return;
            oldestFirst = new ArrayList<>(LIVE.keySet());
        }
        int excess = oldestFirst.size() - MAX;
        for (PySpider spider : oldestFirst) {
            if (excess <= 0) break;
            // 已经死掉的只需销账；忙碌中的跳过（软上限，下次登记时再收敛）
            if (!spider.hasLiveRuntime() || spider.evictIdle()) {
                forget(spider);
                excess--;
            }
        }
    }
}
