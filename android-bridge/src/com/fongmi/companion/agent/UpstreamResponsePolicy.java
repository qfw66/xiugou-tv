package com.fongmi.companion.agent;

import com.fongmi.companion.ParseStage;
import java.io.IOException;
import java.lang.reflect.Field;
import java.util.List;
import okhttp3.*;

/** Narrow response recovery; never changes a payload's shared client or TLS policy. */
final class UpstreamResponsePolicy {
    private static final ThreadLocal<Boolean> RETRYING = ThreadLocal.withInitial(() -> false);
    /** host+path of the request that produced the current UPSTREAM diagnostic on this thread. */
    private static final ThreadLocal<String> FAILED_ENDPOINT = new ThreadLocal<>();
    private UpstreamResponsePolicy() {}

    /**
     * @param raw     the request as the payload's earlier interceptors handed it to {@code hook}
     * @param rewritten the request after {@code hook}'s own rewrites, which produced {@code response}
     */
    static Response handle(Interceptor hook, Request raw, Request rewritten, Response response, Call call)
            throws IOException {
        boolean cfError = isCloudflareDnsError(response);
        // Cloudflare answers 1034 at the edge, before the origin sees the request, so replaying a POST
        // whose body can be rewritten byte-for-byte has no server-side effect (光影 search captcha).
        if (cfError && !RETRYING.get() && isReplayable(rewritten) && isReplayable(response.request())
                && call != null && !call.isCanceled() && !Thread.currentThread().isInterrupted()) {
            OkHttpClient client = clientOf(call);
            if (client != null && client.dns() != Dns.SYSTEM) {
                OkHttpClient.Builder builder = client.newBuilder().dns(Dns.SYSTEM);
                // Interceptors before the hook already ran for `raw`; running them again would repeat
                // payload signing, counters or header additions.
                List<Interceptor> interceptors = builder.interceptors();
                int index = indexOf(interceptors, hook);
                if (index > 0) interceptors.subList(0, index).clear();
                Call retry = builder.build().newCall(index >= 0 ? raw : rewritten);
                response.close();
                RETRYING.set(true);
                try {
                    System.out.println("[DNSFallback] HTTP 403/1034: retry " + raw.method()
                            + " with system DNS: " + raw.url().host());
                    if (call.isCanceled()) retry.cancel();
                    response = retry.execute();
                } finally {
                    RETRYING.remove();
                }
                cfError = isCloudflareDnsError(response);
            }
        }
        String endpoint = endpointOf(response.request());
        if (cfError) {
            markUpstream(endpoint, "站源网络请求被拒绝（HTTP 403 / 1034）");
        } else if (isMissingSearchTemplate(response)) {
            markUpstream(endpoint, "源站搜索模板缺失：vod_search.html，请稍后再试");
        } else if (response.isSuccessful() && endpoint.equals(FAILED_ENDPOINT.get())) {
            // The same endpoint later answered normally: the earlier rejection no longer explains an empty result.
            ParseStage.Failure current = ParseStage.current();
            if (current != null && ParseStage.UPSTREAM.equals(current.stage)) ParseStage.clearFailure();
            FAILED_ENDPOINT.remove();
        }
        return response;
    }

    private static void markUpstream(String endpoint, String detail) {
        FAILED_ENDPOINT.set(endpoint);
        ParseStage.fail(ParseStage.UPSTREAM, detail);
    }

    private static String endpointOf(Request request) {
        return request.method() + " " + request.url().host() + request.url().encodedPath();
    }

    private static int indexOf(List<Interceptor> interceptors, Interceptor hook) {
        for (int i = 0; i < interceptors.size(); i++) if (interceptors.get(i) == hook) return i;
        return -1;
    }

    private static boolean isGet(Request request) {
        return "GET".equals(request.method()) && request.body() == null;
    }

    private static final long MAX_REPLAY_BODY = 64 * 1024;

    /**
     * GET, or a POST whose body OkHttp itself builds from in-memory data ({@link FormBody} /
     * {@code RequestBody.create(...)}): writing it again yields identical bytes. Custom or
     * streaming bodies may be one-shot and are never replayed.
     */
    static boolean isReplayable(Request request) {
        if (isGet(request)) return true;
        if (!"POST".equals(request.method())) return false;
        RequestBody body = request.body();
        if (body == null) return false;
        String type = body.getClass().getName();
        if (!(body instanceof FormBody) && !type.startsWith("okhttp3.RequestBody$")) return false;
        try {
            long length = body.contentLength();
            return length >= 0 && length <= MAX_REPLAY_BODY;
        } catch (IOException | RuntimeException error) {
            return false;
        }
    }

    /** Classification must never fail the payload's request. */
    private static String peek(Response response, long max) {
        try {
            return response.body() == null ? "" : response.peekBody(max).string();
        } catch (IOException | RuntimeException error) {
            return null;
        }
    }

    private static boolean isCloudflareDnsError(Response response) {
        if (response.code() != 403) return false;
        String text = peek(response, 256);
        return text != null && text.trim().equalsIgnoreCase("error code: 1034");
    }

    private static boolean isMissingSearchTemplate(Response response) {
        HttpUrl url = response.request().url();
        if (response.code() != 200 || !isGet(response.request())
                || !url.encodedPath().endsWith("/index.php")
                || !"vod-search".equals(url.queryParameter("m"))) return false;
        String text = peek(response, 1024);
        return text != null && text.trim().matches("缺少文件[：:]\\s*/[^\\r\\n<>]{1,900}/vod_search\\.html");
    }

    /** OkHttp 3.12 RealCall has no public client accessor; unknown implementations fail closed. */
    private static OkHttpClient clientOf(Call call) {
        if (!"okhttp3.RealCall".equals(call.getClass().getName())) return null;
        try {
            Field field = call.getClass().getDeclaredField("client");
            field.setAccessible(true);
            Object client = field.get(call);
            return client instanceof OkHttpClient ? (OkHttpClient) client : null;
        } catch (ReflectiveOperationException | RuntimeException error) {
            return null;
        }
    }
}
