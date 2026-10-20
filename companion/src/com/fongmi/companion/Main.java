package com.fongmi.companion;

import com.fongmi.bridge.AndroidBridge;
import com.fongmi.companion.selfcheck.PayloadInspector;

/**
 * 桌面端（修狗TV）的 Java 侧启动入口。
 *
 * <p>真正的桥接能力都在 {@code android-bridge} 模块里（android.* 运行时 shim、
 * CatVod 爬虫契约、加固载荷加载器、RPC 服务）。本类只负责：解析 {@code --port} 与
 * {@code --self-check}、调门面起服务、打印握手行、挂停机钩子、保持进程存活。
 *
 * <p>握手行的格式 {@code [COMPANION_READY] PORT=<n>} 被 Flutter 侧的
 * {@code companion_process_manager} 解析，改动会导致桌面端连不上 Java 服务，
 * 因此这里保持逐字节不变。
 *
 * <p>{@code --stdin-watch=on} 时额外监视 stdin：修狗TV 的 Flutter 侧持有通往本
 * 进程的 stdin 管道，主进程异常退出（崩溃/被强杀）时管道关闭、read 返回 EOF，
 * 本进程随即自行退出，避免留下无人回收的孤立 java 进程（⑥ 内存批）。默认关闭：
 * 其它启动方式（脚本探活、手工调试）的 stdin 可能直接是 NUL，常开会导致秒退。
 */
public class Main {

    public static void main(String[] args) {
        int port = 0; // 0 = 由系统分配空闲端口
        boolean stdinWatch = false; // --stdin-watch=on 启用，默认关闭（见类注释）
        for (String arg : args) {
            if (arg.startsWith("--port=")) {
                try {
                    port = Integer.parseInt(arg.substring(7).trim());
                } catch (NumberFormatException ignored) {}
            } else if (arg.startsWith("--self-check=")) {
                // 自检初始状态：只有显式 on/true/1 才算开启，其余（含缺省）一律关闭。
                String value = arg.substring("--self-check=".length()).trim();
                boolean on = "on".equalsIgnoreCase(value)
                        || "true".equalsIgnoreCase(value)
                        || "1".equals(value);
                PayloadInspector.setEnabled(on);
                // 关闭时保持完全静默（默认即关闭，不该给普通用户刷启动日志）；
                // 只在开启时打一行 ASCII 以便核对参数已生效。
                if (on) {
                    System.out.println("[SelfCheck] toggle=on");
                }
            } else if (arg.startsWith("--stdin-watch=")) {
                // 与 --self-check 同口径：只有显式 on/true/1 才启用，缺省关闭。
                String value = arg.substring("--stdin-watch=".length()).trim();
                stdinWatch = "on".equalsIgnoreCase(value)
                        || "true".equalsIgnoreCase(value)
                        || "1".equals(value);
            }
        }

        // 安装 Android 运行时补丁（AES/CBC/PKCS7Padding 等），幂等。
        AndroidBridge.install();

        try {
            int boundPort = AndroidBridge.serve(port);
            System.out.println("[COMPANION_READY] PORT=" + boundPort);
            System.out.flush();

            if (stdinWatch) {
                startStdinWatchdog();
            }

            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                System.out.println("[COMPANION_STOPPING]");
                AndroidBridge.shutdown();
            }));

            // Keep alive
            Thread.currentThread().join();
        } catch (Exception e) {
            System.err.println("[COMPANION_ERROR] " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    /**
     * 监视 stdin 的守护线程：读到 EOF（或管道异常）即认为父进程已离开，自行退出。
     * 退出走 System.exit(0)，会触达停机钩子，日志中可见 [COMPANION_STOPPING]。
     */
    private static void startStdinWatchdog() {
        Thread thread = new Thread(() -> {
            try {
                byte[] buffer = new byte[256];
                while (System.in.read(buffer) != -1) {
                    // 输入内容无意义：父进程只用这条管道传递"存活"信号。
                }
            } catch (Exception ignored) {
                // 管道中断与 EOF 同等处理。
            }
            System.out.println("[COMPANION_STDIN_EOF]");
            System.out.flush();
            System.exit(0);
        }, "companion-stdin-watch");
        thread.setDaemon(true);
        thread.start();
    }
}
