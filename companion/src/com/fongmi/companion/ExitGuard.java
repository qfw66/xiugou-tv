package com.fongmi.companion;

/**
 * 拦截「载荷自己杀进程」的退出请求。
 *
 * <p>实测（2026-11-16 用户便携包日志）：某次 {@code action@pan_config} 期间 companion JVM
 * 直接以 exit code=1 结束，日志里没有 {@code [COMPANION_ERROR]}、也没有栈——说明退出不是宿主
 * 代码发起（{@link Main#main} 的异常出口会打日志），而是被加载的站源载荷调用了
 * {@code System.exit(1)}。进程一死，RPC 只能报「无法连接站源服务，请重试」，用户看到的就是
 * 自愈重启 → 再扫码 → 再死的死循环。
 *
 * <p>本类在 JVM 启动后安装一个只关心退出的 {@link SecurityManager}：宿主帧发起的退出照旧放行，
 * 载荷帧发起的退出先打一条可读日志 + 调用栈（写进 companion.log），再抛
 * {@link SecurityException} 让该次 RPC 失败——进程存活，下一次动作还能跑。
 *
 * <p>JDK 17+ 需要 {@code -Djava.security.manager=allow} 才能 {@code setSecurityManager}，
 * 参数见 {@code lib/core/companion/companion_process_manager.dart} 的
 * {@code companionJvmTuningArgs}；装不上时只打一行日志，不影响其它功能。
 *
 * <p>注意：{@code Runtime.halt()} 不受 SecurityManager 管辖，拦不住——这是 JDK 的既定行为。
 */
public final class ExitGuard {

    private static volatile boolean installed;

    private ExitGuard() {
    }

    /** 幂等安装；失败只记录，不影响服务启动。 */
    public static void install() {
        if (installed) return;
        try {
            if (System.getSecurityManager() != null) {
                installed = true;
                return;
            }
            System.setSecurityManager(new Guard());
            installed = true;
            installDiagnostics();
            System.out.println("[ExitGuard] installed");
        } catch (Throwable error) {
            System.out.println("[ExitGuard] install skipped: " + error);
        }
    }

    /**
     * 进程级诊断：把「有序退出」「halt／原生崩溃」「线程未捕获异常」区分开。
     *
     * <p>关停钩子在 {@code System.exit} 与正常返回时触发，{@code Runtime.halt} 与 JVM 崩溃不触发；
     * 因此日志里没有 blocked、也没有 hook 行，就说明载荷走了 halt 或进程被外部杀掉。
     */
    private static void installDiagnostics() {
        try {
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                System.out.println("[ExitGuard] shutdown-hook fired（有序退出；halt 与崩溃不会触发本行）");
                System.out.flush();
            }, "exitguard-shutdown"));
        } catch (Throwable ignored) {
            // 诊断不可用不影响主流程。
        }
        try {
            Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
                System.out.println("[ExitGuard] uncaught on thread=" + thread.getName() + " -> " + error);
                error.printStackTrace(System.out);
                System.out.flush();
            });
        } catch (Throwable ignored) {
        }
    }

    static boolean isInstalled() {
        return installed;
    }

    /** 直接发起退出的类；找不到返回 null。 */
    static Class<?> callerClassOfExit(Class<?>[] context) {
        if (context == null) return null;
        for (Class<?> frame : context) {
            if (frame == null) continue;
            String name = frame.getName();
            // 跳过 JDK 的 System/Runtime 帧，也跳过本类自己（Guard 在调用栈里一定存在，
            // 若不跳过，任何退出都会被误判为「宿主发起」而放行）。
            if (name.startsWith("java.lang.") || name.startsWith("java.security.")) continue;
            if (name.startsWith("com.fongmi.companion.ExitGuard")) continue;
            return frame;
        }
        return null;
    }

    /**
     * 宿主判定看<b>类加载器</b>，不看包名。
     *
     * <p>载荷（dex jar）由 PayloadClassLoader / DexClassLoader 定义，其壳类甚至可能落在
     * {@code com.fongmi.companion.*} 包里；按前缀放行会把这类退出请求错判成宿主行为，
     * 于是既拦不住又没有任何日志。此处只有 companion 自身类加载器加载的类才算宿主。
     */
    static boolean isHost(Class<?> caller) {
        if (caller == null) return true;
        ClassLoader own = ExitGuard.class.getClassLoader();
        ClassLoader loader = caller.getClassLoader();
        if (loader == null) return own == null;
        return loader == own;
    }

    private static final class Guard extends SecurityManager {

        @Override
        public void checkPermission(java.security.Permission permission) {
            // 只关心退出；其它权限一律放行，避免打断载荷的反射/文件访问。
        }

        @Override
        public void checkPermission(java.security.Permission permission, Object context) {
        }

        @Override
        public void checkExit(int status) {
            Class<?>[] context = getClassContext();
            Class<?> caller = callerClassOfExit(context);
            if (isHost(caller)) return;
            String name = caller == null ? "" : caller.getName();
            report(status, name, context);
            throw new SecurityException(
                    "站源载荷请求退出站源服务（exit=" + status + "，来源 " + name + "），已被拦截");
        }
    }

    private static void report(int status, String caller, Class<?>[] context) {
        try {
            System.out.println("[ExitGuard] blocked System.exit(" + status + ") from " + caller
                    + " thread=" + Thread.currentThread().getName());
            int printed = 0;
            for (Class<?> frame : context) {
                if (frame == null) continue;
                String name = frame.getName();
                if (name.startsWith("java.lang.") || name.startsWith("java.security.")) continue;
                System.out.println("[ExitGuard]   at " + name);
                if (++printed >= 8) break;
            }
            System.out.flush();
        } catch (Throwable ignored) {
            // 日志失败不能影响拦截本身。
        }
    }
}
