package com.fongmi.companion.agent;

import java.util.Collections;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import okhttp3.Call;

/**
 * 按「RPC 标签」登记在途的 OkHttp 请求，使调用可以被真正中止。
 *
 * <p>背景：{@code SpiderServer.runWithWatchdog} 超时后只做过 {@code future.cancel(true)}，
 * 那只发 interrupt；spider 卡在 OkHttp 同步 {@code execute()} 的 socket read 上时
 * interrupt 打不断它（JDK 语义），worker 会长期占着 {@code callPool} 的槽位
 * （SynchronousQueue + 上限 64，满了直接 503，不排队），一个挂死的站就能慢慢吃光整台
 * companion 的处理能力。
 *
 * <p>抓手：构建期补丁（{@code PatchOkHttp}）把 {@code HttpLogHook.install(builder)}
 * 注入 {@code OkHttpClient$Builder.build()}，载荷自己 new 的客户端都会带上这条拦截器；
 * 拦截器里 {@code chain.call()} 拿到的就是那次请求本体（本仓 okhttp-3.12.1 的
 * {@code Interceptor$Chain} 已声明 {@code Call call()}，javap 实测确认）。
 * {@code Call.cancel()} 立即关 socket，阻塞中的 {@code execute()} 以 IOException 退出，
 * worker 归还线程池。
 *
 * <p>边界：标签靠 {@code ThreadLocal} 传递，因此<b>只覆盖同步 {@code execute()}</b>。
 * 载荷改用 {@code enqueue()} 时拦截器跑在 OkHttp dispatcher 线程上，取不到标签，
 * 该请求不会被取消——已知限制，不做兜底假装解决。
 *
 * <p>类加载器：spider 由 {@code DexSpiderLoader} 的
 * {@code URLClassLoader(jar, parent = 应用类加载器)} 加载，parent-first 委派使
 * {@code okhttp3.*} 与本类都只有应用类加载器那一份，注册表是全进程唯一的。
 */
public final class CallRegistry {

    private static final Map<String, Set<Call>> IN_FLIGHT = new ConcurrentHashMap<>();
    /**
     * 已被中止过的标签 → 标记过期时刻（毫秒）。spider 内部常常连发好几个请求（翻页轮询、
     * 先取 token 再取列表），光取消当时在途的那一批不够 —— 不设这个标记，取消后它又会
     * 发出新的请求，照样把 worker 卡在 socket read 上。
     *
     * <p>正常路径下标记的生命周期等于一次 RPC：{@code bind} 清旧、{@code unbind} 收尾。
     * 但「取消请求比 worker 退出晚到」是可能的（UI 点了叉、调用其实已经返回），
     * 那次的标记没人清理，所以给每个标记设 TTL：它只对还在跑的 RPC 有意义，
     * 而任何还在跑的 RPC 都早已被 {@code callPool} 的看门狗超时收走。
     */
    private static final Map<String, Long> CANCELLED = new ConcurrentHashMap<>();
    private static final long CANCEL_MARK_TTL_MS = 600_000L;
    private static final long CANCEL_SWEEP_INTERVAL_MS = 60_000L;
    private static final java.util.concurrent.atomic.AtomicLong NEXT_SWEEP_AT =
            new java.util.concurrent.atomic.AtomicLong(0L);
    private static final ThreadLocal<String> CURRENT_TAG = new ThreadLocal<>();

    private CallRegistry() {
    }

    /**
     * 在工作线程内部绑定当前 RPC 标签。
     *
     * @return 绑定之前的标签，供 {@link #unbind(String)} 成对恢复
     */
    public static String bind(String tag) {
        String previous = CURRENT_TAG.get();
        if (tag == null || tag.isEmpty()) {
            CURRENT_TAG.remove();
        } else {
            CANCELLED.remove(tag);
            CURRENT_TAG.set(tag);
        }
        return previous;
    }

    /** 解绑当前线程的标签；曾有过父标签时恢复它，避免线程复用串味。 */
    public static void unbind(String previous) {
        String tag = CURRENT_TAG.get();
        if (tag != null) {
            CANCELLED.remove(tag);
            Set<Call> left = IN_FLIGHT.remove(tag);
            if (left != null && !left.isEmpty()) {
                System.err.println("[CallRegistry] tag=" + tag + " 结束时仍有 "
                        + left.size() + " 个未登记的请求，逐个取消");
                for (Call call : new java.util.ArrayList<>(left)) {
                    try {
                        call.cancel();
                    } catch (Throwable ignored) {
                    }
                }
            }
        }
        if (previous == null) {
            CURRENT_TAG.remove();
        } else {
            CURRENT_TAG.set(previous);
        }
    }

    /** 当前线程正在服务的 RPC 标签；非 spider 调用线程返回 null。 */
    public static String currentTag() {
        return CURRENT_TAG.get();
    }

    /**
     * 把一次请求登记到当前标签下。
     *
     * @return 是否真的登记了（false 表示没有标签，调用方就不必再注销）
     */
    public static boolean register(Call call) {
        String tag = CURRENT_TAG.get();
        if (tag == null || call == null) {
            return false;
        }
        if (isCancelled(tag)) {
            // 这次 RPC 已经被中止过，新冒出来的请求直接掐掉，不再占 socket
            try {
                call.cancel();
            } catch (Throwable ignored) {
            }
            return false;
        }
        setFor(tag).add(call);
        return true;
    }

    /** 请求结束（成功或失败）后注销，防止 Call 引用长期滞留。 */
    public static void unregister(Call call) {
        String tag = CURRENT_TAG.get();
        if (tag == null || call == null) {
            return;
        }
        Set<Call> calls = IN_FLIGHT.get(tag);
        if (calls == null) {
            return;
        }
        boolean empty;
        synchronized (calls) {
            calls.remove(call);
            empty = calls.isEmpty();
        }
        if (empty) {
            IN_FLIGHT.remove(tag, calls);
        }
    }

    /**
     * 中止该标签下所有在途请求。
     *
     * <p>每个 {@code Call.cancel()} 都单独 try：一次取消里只要有一个请求已经结束了，
     * 不能让异常把后面还没取消的连带跳过；取消逻辑绝不能污染业务调用链。
     *
     * @return 实际发起取消的请求数
     */
    public static int cancel(String tag) {
        if (tag == null || tag.isEmpty()) {
            return 0;
        }
        sweepExpired();
        CANCELLED.put(tag, Long.valueOf(System.currentTimeMillis() + CANCEL_MARK_TTL_MS));
        Set<Call> calls = IN_FLIGHT.remove(tag);
        if (calls == null || calls.isEmpty()) {
            return 0;
        }
        int cancelled = 0;
        synchronized (calls) {
            for (Call call : calls) {
                try {
                    call.cancel();
                    cancelled++;
                } catch (Throwable ignored) {
                }
            }
            calls.clear();
        }
        return cancelled;
    }

    /** 该标签是否已被中止且标记未过期。过期即视为未取消，并顺手清掉。 */
    private static boolean isCancelled(String tag) {
        Long deadline = CANCELLED.get(tag);
        if (deadline == null) {
            return false;
        }
        if (deadline.longValue() > System.currentTimeMillis()) {
            return true;
        }
        CANCELLED.remove(tag, deadline);
        return false;
    }

    /**
     * 清理过期标记。只在 {@link #cancel(String)} 里按时间间隔触发，
     * 让「取消请求比 worker 退出晚到」留下的孤儿标记不至于无界增长；
     * 空闲时不做任何后台线程。
     */
    private static void sweepExpired() {
        long now = System.currentTimeMillis();
        long next = NEXT_SWEEP_AT.get();
        if (now < next || !NEXT_SWEEP_AT.compareAndSet(next, now + CANCEL_SWEEP_INTERVAL_MS)) {
            return;
        }
        for (Map.Entry<String, Long> entry : CANCELLED.entrySet()) {
            Long deadline = entry.getValue();
            if (deadline != null && deadline.longValue() <= now) {
                CANCELLED.remove(entry.getKey(), deadline);
            }
        }
    }

    /** 该标签当前登记的在途请求数，用于日志与回归观察。 */
    public static int inFlightCount(String tag) {
        Set<Call> calls = tag == null ? null : IN_FLIGHT.get(tag);
        if (calls == null) {
            return 0;
        }
        synchronized (calls) {
            return calls.size();
        }
    }

    /** 进程退出/服务停机时清空，不给下一个实例留残留。 */
    public static void clear() {
        for (String tag : new java.util.ArrayList<>(IN_FLIGHT.keySet())) {
            cancel(tag);
        }
        IN_FLIGHT.clear();
        CANCELLED.clear();
    }

    private static Set<Call> setFor(String tag) {
        return IN_FLIGHT.computeIfAbsent(tag, k -> Collections.synchronizedSet(new HashSet<Call>()));
    }
}
