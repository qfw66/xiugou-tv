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
 */
public class Main {

    public static void main(String[] args) {
        int port = 0; // 0 = 由系统分配空闲端口
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
            }
        }

        // 安装 Android 运行时补丁（AES/CBC/PKCS7Padding 等），幂等。
        AndroidBridge.install();

        try {
            int boundPort = AndroidBridge.serve(port);
            System.out.println("[COMPANION_READY] PORT=" + boundPort);
            System.out.flush();

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
}
