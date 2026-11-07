package com.fongmi.companion.ipc;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * 按行通信的常驻子进程：一个常驻读线程 + 有界队列，调用方带超时取行。
 *
 * <p>为什么不能「每次调用起一个读线程、超时后 close 读流」：读线程阻塞在 {@code readLine} 时持有
 * {@code BufferedReader} 的内部锁，另一线程的 {@code close()} 会一直等这把锁（JDK 21.0.6 实测 5 s 不返回）。
 * 子进程挂起时它永远拿不到，排在后面的 {@code destroy} 也永远执行不到，调用方若还持着全局锁就整体死锁。
 *
 * <p>所以关闭顺序固定为：先强杀进程 → 管道 EOF → 读线程自行结束；绝不从别的线程关读流。
 */
public final class LineProcess implements AutoCloseable {

    /** 队列上限：子进程刷屏时丢弃最旧的行，避免内存随杂讯无限增长。 */
    private static final int MAX_PENDING_LINES = 4096;
    /** EOF 哨兵（按引用比较，不会与真实行混淆）。 */
    private static final String EOF = new String("<eof>");

    private final Process process;
    private final BufferedWriter writer;
    private final LinkedBlockingQueue<String> lines = new LinkedBlockingQueue<>();
    private volatile boolean eof;

    private LineProcess(Process process, String name) {
        this.process = process;
        this.writer = new BufferedWriter(new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8));
        Thread reader = new Thread(() -> pump(new BufferedReader(
                new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))), name + "-reader");
        reader.setDaemon(true);
        reader.start();
    }

    /** 启动子进程并开始读取其 stdout。 */
    public static LineProcess start(ProcessBuilder builder, String name) throws IOException {
        return new LineProcess(builder.start(), name);
    }

    private void pump(BufferedReader reader) {
        try (reader) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (lines.size() >= MAX_PENDING_LINES) lines.poll();
                lines.offer(line);
            }
        } catch (IOException ignored) {
            // 管道断开与 EOF 同等处理
        } finally {
            eof = true;
            lines.offer(EOF);
        }
    }

    /** 写一行并 flush。 */
    public void send(String line) throws IOException {
        writer.write(line);
        writer.newLine();
        writer.flush();
    }

    /**
     * 取下一行。
     *
     * @return 下一行；超时或子进程输出已结束时返回 null（{@link #isEof()} 可区分两者）
     */
    public String readLine(long timeoutMs) throws InterruptedException {
        if (eof && lines.isEmpty()) return null;
        String line = lines.poll(Math.max(1, timeoutMs), TimeUnit.MILLISECONDS);
        if (line == EOF) {
            lines.offer(EOF); // 留给后续调用，保持「EOF 之后一直返回 null」
            return null;
        }
        return line;
    }

    /**
     * 与 {@link #readLine(long)} 相同，但调用线程被 interrupt 时不放弃等待，直到拿到行或超时，
     * 返回前再恢复中断标记。
     *
     * <p>一问一答的协议里，请求已写出后半途放弃会让子进程的应答错位，调用方只能杀掉重启；
     * 而调用方（如载荷读本地登录态时的解密）拿到 null 会把它当成永久结果缓存下来。
     * 等待本身有超时上限，所以不必响应中断。
     */
    public String readLineIgnoringInterrupt(long timeoutMs) {
        long deadline = System.currentTimeMillis() + Math.max(1, timeoutMs);
        boolean interrupted = false;
        try {
            while (true) {
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) return null;
                try {
                    return readLine(left);
                } catch (InterruptedException e) {
                    interrupted = true;
                }
            }
        } finally {
            if (interrupted) Thread.currentThread().interrupt();
        }
    }

    /** 子进程 stdout 是否已结束。 */
    public boolean isEof() {
        return eof;
    }

    public boolean isAlive() {
        return process.isAlive() && !eof;
    }

    public long pid() {
        return process.pid();
    }

    /** 先强杀进程，再关写端；读线程随管道 EOF 自行退出。可重复调用。 */
    @Override
    public void close() {
        process.destroyForcibly();
        try {
            process.waitFor(2, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        try {
            writer.close();
        } catch (IOException ignored) {
            // 进程已死，写端关闭失败无影响
        }
    }
}
