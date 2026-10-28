package com.fongmi.companion.agent;

import com.github.catvod.utils.DebugLog;
import com.github.catvod.utils.HeaderOverride;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

import okhttp3.Call;
import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.Buffer;

/**
 * OkHttp 钩子：由 {@link HttpLogAgent} / 构建期 {@link PatchOkHttp} 注入到
 * {@code OkHttpClient.Builder.build()} 入口，保证载荷自己 new 出来的客户端也能被挂上。
 *
 * <p>它承担两件事，二者门控不同，别再混成一个开关：
 * <ul>
 *   <li><b>在途请求登记</b>（{@link CallRegistry}）——必须<b>无条件装</b>，
 *       否则正式包（调试开关为 false）就没有任何中止手段，挂死的站会吃光
 *       {@code SpiderServer.callPool} 的 64 个槽；</li>
 *   <li><b>请求/响应日志</b>——仍按 {@code DebugLog.httpEnabled()} 门控，
 *       关着时不多打一行、也不多 peek 一次响应体。</li>
 * </ul>
 */
public final class HttpLogHook {

    private static final String TAG = "HTTP";

    private HttpLogHook() {
    }

    /**
     * 由 agent 注入到每个 Builder.build() 的开头。重复 install 是幂等的。
     *
     * <p>注意这里<b>不再</b>按调试开关早退：开关只决定日志打不打，取消能力必须常在。
     */
    public static void install(OkHttpClient.Builder builder) {
        if (builder == null) return;
        try {
            for (Interceptor interceptor : builder.interceptors()) {
                if (interceptor instanceof LoggingInterceptor) return;
            }
            builder.addInterceptor(new LoggingInterceptor());
        } catch (Throwable t) {
            System.err.println("[DBG][AGENT] add interceptor failed: " + t);
        }
    }

    static final class LoggingInterceptor implements Interceptor {

        @Override
        public Response intercept(Chain chain) throws IOException {
            Request request = HeaderOverride.apply(DoubanRewrite.apply(chain.request()));
            final boolean logging = DebugLog.httpEnabled();
            long id = logging ? DebugLog.nextId() : 0L;
            long started = System.nanoTime();
            if (logging) {
                DebugLog.httpRequest(id, request.method(), request.url().toString(),
                        headers(request), body(request));
            }

            // 登记这次请求本体，让 /spider/cancel 与看门狗超时可以真的把它掐断。
            // chain.call() 拿不到也不能影响业务，全程按「拿不到就不追踪」处理。
            Call call = null;
            try {
                call = chain.call();
            } catch (Throwable ignored) {
            }
            boolean tracked = call != null && CallRegistry.register(call);
            try {
                Response response = chain.proceed(request);
                if (logging) {
                    long cost = (System.nanoTime() - started) / 1_000_000L;
                    byte[] peek = new byte[0];
                    try {
                        ResponseBody peeked = response.peekBody(DebugLog.maxChars());
                        if (peeked != null) peek = peeked.bytes();
                    } catch (Throwable ignored) {
                    }
                    long length = response.body() == null ? -1 : response.body().contentLength();
                    DebugLog.httpResponse(id, response.code(), cost,
                            response.header("Content-Type"), length, peek);
                }
                return response;
            } catch (Throwable t) {
                if (logging) DebugLog.httpError(id, t);
                throw t;
            } finally {
                if (tracked) CallRegistry.unregister(call);
            }
        }

        private static Map<String, String> headers(Request request) {
            Map<String, String> map = new LinkedHashMap<>();
            for (String name : request.headers().names()) map.put(name, request.header(name));
            return map;
        }

        private static byte[] body(Request request) {
            try {
                if (request.body() == null) return null;
                Buffer buffer = new Buffer();
                request.body().writeTo(buffer);
                return buffer.readByteArray();
            } catch (Throwable t) {
                return null;
            }
        }
    }
}
