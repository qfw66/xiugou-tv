package com.fongmi.companion.agent;

import com.github.catvod.utils.DebugLog;
import com.github.catvod.utils.HeaderOverride;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.Buffer;

/**
 * OkHttp 日志钩子：由 {@link HttpLogAgent} 在 {@code OkHttpClient.Builder.build()}
 * 入口注入，保证载荷自己 new 出来的客户端也能把请求/响应打进控制台。
 */
public final class HttpLogHook {

    private static final String TAG = "HTTP";

    private HttpLogHook() {
    }

    /** 由 agent 注入到每个 Builder.build() 的开头。重复 install 是幂等的。 */
    public static void install(OkHttpClient.Builder builder) {
        if (builder == null) return;
        if (!DebugLog.httpEnabled() && !HeaderOverride.enabled()) return;
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
            Request request = HeaderOverride.apply(chain.request());
            long id = DebugLog.nextId();
            long started = System.nanoTime();
            DebugLog.httpRequest(id, request.method(), request.url().toString(),
                    headers(request), body(request));
            try {
                Response response = chain.proceed(request);
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
                return response;
            } catch (Throwable t) {
                DebugLog.httpError(id, t);
                throw t;
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
