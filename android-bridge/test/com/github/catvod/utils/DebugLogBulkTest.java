package com.github.catvod.utils;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 调试日志（-Dxiugou.debug=true）的两条约束：
 * <ol>
 *   <li>Cookie / Authorization 等请求头默认打码，只有显式 {@code -Dxiugou.debug.secrets=true} 才原样输出；</li>
 *   <li>带 Range 的分段下载（网盘播放时每 64 KB 一个请求，一秒几十上百个）不逐条打印，
 *       按主机定时汇总一行；普通请求照旧逐条打印，分段请求出错照旧立即打印。</li>
 * </ol>
 * 运行：java -ea -Dxiugou.debug=true -cp &lt;classes&gt; com.github.catvod.utils.DebugLogBulkTest
 */
public final class DebugLogBulkTest {

    public static void main(String[] args) {
        assert DebugLog.httpEnabled() : "run with -Dxiugou.debug=true";
        secretsMaskedByDefault();
        rangeRequestsAreSummarized();
        rangeErrorsStillPrinted();
        System.out.println("DebugLogBulkTest OK");
    }

    private static void secretsMaskedByDefault() {
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Cookie", "__pus=SECRET_COOKIE_VALUE");
        headers.put("Authorization", "Bearer SECRET_TOKEN_VALUE");
        headers.put("User-Agent", "UA-VISIBLE");
        final long id = DebugLog.nextId();
        String out = capture(() -> {
            DebugLog.httpRequest(id, "GET", "https://api.example.com/list?page=1", headers, null);
            DebugLog.httpResponse(id, 200, 5, "application/json", 11, "{\"code\":0}".getBytes(StandardCharsets.UTF_8));
        });
        assert out.contains("--> GET https://api.example.com/list?page=1") : "ordinary request must still be printed: " + out;
        assert out.contains("<-- 200") : "ordinary response must still be printed: " + out;
        assert out.contains("Cookie=***") && out.contains("Authorization=***") : "secrets masked by default: " + out;
        assert !out.contains("SECRET_COOKIE_VALUE") && !out.contains("SECRET_TOKEN_VALUE") : "no raw secret: " + out;
        assert out.contains("User-Agent=UA-VISIBLE") : "other headers stay visible: " + out;
    }

    private static void rangeRequestsAreSummarized() {
        byte[] chunk = new byte[] { (byte) 0xbe, 0x7b, 0x68, (byte) 0xf2, (byte) 0xa2, (byte) 0x8a, (byte) 0x8b, (byte) 0xb2 };
        String live = capture(() -> {
            for (int i = 0; i < 50; i++) {
                long id = DebugLog.nextId();
                Map<String, String> headers = new LinkedHashMap<>();
                headers.put("Cookie", "SECRET_COOKIE_VALUE");
                headers.put("Range", "bytes=" + (i * 65536L) + "-" + (i * 65536L + 65535));
                DebugLog.httpRequest(id, "GET", "https://dl.example.com/v/file.mp4?auth_key=SECRET_AUTH_KEY", headers, null);
                DebugLog.httpResponse(id, 206, 10, "application/octet-stream", 65536, chunk);
            }
        });
        assert live.isEmpty() : "range chunks must not be printed one by one: " + live;

        String summary = capture(DebugLog::flushBulk);
        assert summary.contains("dl.example.com") : "summary names the host: " + summary;
        assert summary.contains("50 次") && summary.contains("206×50") : "summary counts the chunks: " + summary;
        assert summary.contains("3.1 MB") : "summary adds up the bytes (50 × 64 KB): " + summary;
        assert !summary.contains("SECRET_AUTH_KEY") && !summary.contains("SECRET_COOKIE_VALUE") : "no url query / cookie: " + summary;
        assert summary.trim().split("\n").length == 1 : "one line per host: " + summary;

        assert capture(DebugLog::flushBulk).isEmpty() : "nothing new → nothing printed";
    }

    private static void rangeErrorsStillPrinted() {
        final long id = DebugLog.nextId();
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("range", "bytes=0-65535");
        String out = capture(() -> {
            DebugLog.httpRequest(id, "GET", "https://dl.example.com/v/file.mp4", headers, null);
            DebugLog.httpError(id, new IOException("connection reset"));
        });
        assert out.contains("!!") && out.contains("connection reset") && out.contains("dl.example.com")
                : "a failed chunk is printed at once, with its host: " + out;
        String summary = capture(DebugLog::flushBulk);
        assert summary.contains("失败 1") : "the failure is also counted in the summary: " + summary;
    }

    private static String capture(Runnable action) {
        PrintStream original = System.out;
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        System.setOut(new PrintStream(buffer, true, StandardCharsets.UTF_8));
        try {
            action.run();
        } finally {
            System.setOut(original);
        }
        return buffer.toString(StandardCharsets.UTF_8);
    }
}
