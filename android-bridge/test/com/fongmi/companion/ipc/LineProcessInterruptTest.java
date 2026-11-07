package com.fongmi.companion.ipc;

import java.io.File;

/** 独立运行的回归测试：需开启断言（-ea）。子进程用当前 JVM 跑本类的 child 分支。 */
public final class LineProcessInterruptTest {
    public static void main(String[] args) throws Exception {
        if (args.length > 0 && "child".equals(args[0])) {
            child();
            return;
        }
        waitsForReplyWhenInterrupted();
        timesOutWhenInterrupted();
        System.out.println("LineProcessInterruptTest OK");
    }

    /** 模拟一问一答的子进程：读到一行后延迟 300ms 再应答。 */
    private static void child() throws Exception {
        java.io.BufferedReader in = new java.io.BufferedReader(new java.io.InputStreamReader(System.in));
        System.out.println("READY");
        String line;
        while ((line = in.readLine()) != null) {
            Thread.sleep(300);
            System.out.println("OK " + line);
        }
    }

    private static LineProcess startChild() throws Exception {
        String java = new File(new File(System.getProperty("java.home"), "bin"), "java").getAbsolutePath();
        ProcessBuilder builder = new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                LineProcessInterruptTest.class.getName(), "child");
        LineProcess process = LineProcess.start(builder, "test");
        assert "READY".equals(process.readLine(20_000));
        return process;
    }

    private static void waitsForReplyWhenInterrupted() throws Exception {
        try (LineProcess process = startChild()) {
            process.send("ping");
            Thread.currentThread().interrupt();
            String reply = process.readLineIgnoringInterrupt(10_000);
            assert "OK ping".equals(reply) : reply;
            assert Thread.interrupted() : "中断标记应恢复";

            // 应答没有错位：下一问拿到的仍是自己的答案
            process.send("second");
            assert "OK second".equals(process.readLineIgnoringInterrupt(10_000));
            assert !Thread.currentThread().isInterrupted();
        }
    }

    private static void timesOutWhenInterrupted() throws Exception {
        try (LineProcess process = startChild()) {
            Thread.currentThread().interrupt();
            long start = System.currentTimeMillis();
            String reply = process.readLineIgnoringInterrupt(200);
            long cost = System.currentTimeMillis() - start;
            assert reply == null : reply;
            assert cost >= 150 : "应等满超时而不是因中断立即返回: " + cost;
            assert Thread.interrupted() : "中断标记应恢复";
        }
    }
}
