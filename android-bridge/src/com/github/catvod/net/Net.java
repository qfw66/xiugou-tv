package com.github.catvod.net;

import okhttp3.*;
import org.json.JSONArray;
import org.json.JSONObject;
import javax.net.ssl.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import java.util.concurrent.*;

/** Bounded HTTP sessions owned by one spider. Never uses the legacy trust-all client. */
public final class Net implements AutoCloseable {
    private static final int LIMIT = 8 * 1024 * 1024;
    private static final ExecutorService ASYNC = new ThreadPoolExecutor(0, 32, 30, TimeUnit.SECONDS,
            new SynchronousQueue<>(), r -> { Thread t = new Thread(r, "java-sdk-net"); t.setDaemon(true); return t; });
    private final Net parent;
    private final Set<Net> children = ConcurrentHashMap.newKeySet();
    private final Set<Call> calls = ConcurrentHashMap.newKeySet();
    private final Set<StreamResult> streams = ConcurrentHashMap.newKeySet();
    private final Map<String, Entry> cache = new LinkedHashMap<>();
    private final Cookies cookies = new Cookies();
    private volatile boolean closed;
    private OkHttpClient client;
    private record Entry(String value, long expires) {}
    public Net() { this(null); }
    private Net(Net parent) { this.parent = parent; }
    private void open() { if (closed) throw new IllegalStateException("Network session closed"); }
    public synchronized Net session() {
        open(); Net child = new Net(this); children.add(child); return child;
    }
    private synchronized OkHttpClient client() {
        open();
        if (client == null) {
            try {
                TrustManagerFactory tm = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                tm.init((KeyStore) null);
                X509TrustManager trust = Arrays.stream(tm.getTrustManagers()).filter(t -> t instanceof X509TrustManager)
                        .map(t -> (X509TrustManager)t).findFirst().orElseThrow();
                SSLContext tls = SSLContext.getInstance("TLS"); tls.init(null, new TrustManager[]{trust}, null);
                // OkHttp honors the host ProxySelector (direct then configured proxy) and verifies hostnames.
                client = new OkHttpClient.Builder().sslSocketFactory(tls.getSocketFactory(), trust)
                        .cookieJar(cookies).build();
            } catch (Exception e) { throw new IllegalStateException("Cannot initialize TLS", e); }
        }
        return client;
    }
    private Call call(String url, NetOptions options) {
        try { return prepareCall(url, options); }
        catch (org.json.JSONException e) { throw new IllegalArgumentException("Invalid network options"); }
    }
    private Call prepareCall(String url, NetOptions options) throws org.json.JSONException {
        JSONObject o = options.json;
        HttpUrl parsed = HttpUrl.parse(url);
        if (parsed == null || !parsed.username().isEmpty() || !parsed.password().isEmpty())
            throw new IllegalArgumentException("Expected HTTP(S) URL without user info");
        HttpUrl.Builder address = parsed.newBuilder();
        JSONObject params = o.optJSONObject("params");
        if (params != null) for (Iterator<String> it = params.keys(); it.hasNext();) {
            String key = it.next(); Object value = params.get(key);
            if (value instanceof JSONArray values) for (int i=0;i<values.length();i++) address.addQueryParameter(key, values.get(i).toString());
            else if (value != JSONObject.NULL) address.addQueryParameter(key, value.toString());
        }
        Request.Builder request = new Request.Builder().url(address.build());
        if (o.optBoolean("logMetadataOnly", false)) request.tag(com.fongmi.companion.agent.HttpLogHook.MetadataOnly.class,
                com.fongmi.companion.agent.HttpLogHook.MetadataOnly.INSTANCE);
        JSONObject headers = o.optJSONObject("headers");
        if (headers != null) for (Iterator<String> it = headers.keys(); it.hasNext();) {
            String key = it.next(); request.header(key, headers.getString(key));
        }
        if (o.optBoolean("cookie", false)) throw new UnsupportedOperationException("Shared WebView cookies are unavailable; use a session");
        boolean data = o.has("data"), body = o.has("body");
        if (data && body) throw new IllegalArgumentException("body and data are mutually exclusive");
        String method = o.optString("method", data || body ? "POST" : "GET").toUpperCase(Locale.ROOT);
        RequestBody entity = null;
        if (body || data) {
            byte[] bytes;
            String type = headers == null ? null : headers.optString("Content-Type", null);
            if (data && o.optString("postType", "json").equals("form")) {
                JSONObject form = o.getJSONObject("data"); FormBody.Builder f = new FormBody.Builder();
                for (Iterator<String> it=form.keys();it.hasNext();) { String k=it.next(); f.add(k, form.get(k).toString()); }
                entity = f.build(); bytes = null;
            } else {
                Object value = o.get(body ? "body" : "data");
                if (body && value instanceof JSONArray array) {
                    bytes = new byte[array.length()];
                    for (int i=0;i<bytes.length;i++) { int b=array.getInt(i); if(b < -128 || b > 255) throw new IllegalArgumentException("Invalid byte"); bytes[i]=(byte)b; }
                } else {
                    String text = body ? String.valueOf(value) : new JSONArray().put(value).toString();
                    if (data) text = text.substring(1, text.length() - 1);
                    bytes = text.getBytes(StandardCharsets.UTF_8);
                }
                if (type == null) type = data ? "application/json; charset=utf-8" : "text/plain; charset=utf-8";
                if (bytes.length > LIMIT) throw new IllegalArgumentException("Request body too large");
                entity = RequestBody.create(MediaType.parse(type), bytes);
            }
            try { if (entity.contentLength() > LIMIT) throw new IllegalArgumentException("Request body too large"); }
            catch (IOException e) { throw new IllegalArgumentException("Invalid body", e); }
        } else if (Set.of("POST","PUT","PATCH","PROPPATCH","REPORT").contains(method)) entity = RequestBody.create(null, new byte[0]);
        request.method(method, entity);
        long timeout = options.timeout("timeout", 10_000);
        Object redirect = o.opt("redirect"); boolean follow = !Boolean.FALSE.equals(redirect) && !(redirect instanceof Number n && n.intValue() == 0);
        // Explicit false means the payload owns Cookie/Set-Cookie (including refresh removal).
        // An inherited OkHttp jar otherwise replaces the caller's entire Cookie header.
        boolean callerOwnsCookies = o.has("cookie") && !o.optBoolean("cookie", true);
        OkHttpClient effective = client().newBuilder().connectTimeout(timeout, TimeUnit.MILLISECONDS)
                .cookieJar(callerOwnsCookies ? CookieJar.NO_COOKIES : cookies)
                .readTimeout(timeout, TimeUnit.MILLISECONDS).writeTimeout(timeout, TimeUnit.MILLISECONDS)
                .callTimeout(o.optBoolean("streaming", false) ? 0 : options.timeout("callTimeout", 30_000), TimeUnit.MILLISECONDS)
                .followRedirects(follow).followSslRedirects(follow).build();
        Call call = effective.newCall(request.build());
        synchronized (this) { open(); calls.add(call); }
        return call;
    }
    /** Interruptible millisecond delay used by source adapters for bounded polling. */
    public void sleep(long millis) throws InterruptedException {
        if (millis < 0) throw new IllegalArgumentException("Invalid sleep duration");
        open();
        Thread.sleep(millis);
        open();
    }
    public String req(String url, String options) throws IOException {
        NetOptions o = NetOptions.from(options);
        try (StreamResult result = requestStream(url, o)) {
            byte[] raw = bounded(result);
            Object content;
            int buffer = o.json.optInt("buffer", 0);
            if (buffer == 2) content = Base64.getEncoder().encodeToString(raw);
            else if (buffer == 1) { JSONArray a=new JSONArray(); for(byte b:raw) a.put((int)b); content=a; }
            else if (buffer == 0) content = new String(raw, result.charset());
            else throw new IllegalArgumentException("Unsupported buffer mode");
            JSONObject headers = new JSONObject(result.headers);
            // Set-Cookie is not a list header: each field must reach the SDK consumer intact.
            List<String> setCookies = result.response.headers().values("Set-Cookie");
            if (!setCookies.isEmpty()) headers.put("set-cookie", new JSONArray(setCookies));
            return new JSONObject().put("code", result.code).put("headers", headers)
                    .put("content", content).put("url", result.url).toString();
        } catch (org.json.JSONException e) { throw new IOException("Invalid network response", e); }
    }
    public StreamResult requestStream(String url, NetOptions options) throws IOException {
        Call call = call(url, options);
        try {
            Response response = call.execute();
            StreamResult result = new StreamResult(this, call, response);
            synchronized (this) {
                if (closed) { result.close(); throw new IOException("Network session closed"); }
                streams.add(result);
            }
            return result;
        } catch (IOException | RuntimeException e) { calls.remove(call); call.cancel(); throw e; }
    }
    public CompletableFuture<StreamResult> requestStreamAsync(String url, NetOptions options) {
        CompletableFuture<StreamResult> result = new CompletableFuture<>();
        // Track the call before dispatch, so cancellation/close also works while waiting for response headers.
        Call call = call(url, options);
        result.whenComplete((v,e) -> { if (result.isCancelled()) call.cancel(); });
        call.enqueue(new okhttp3.Callback() {
            public void onFailure(Call c, IOException e) { calls.remove(c); result.completeExceptionally(e); }
            public void onResponse(Call c, Response response) {
                StreamResult value = new StreamResult(Net.this, c, response);
                synchronized (Net.this) {
                    if (!closed && !result.isCancelled()) streams.add(value);
                    else { value.close(); result.completeExceptionally(new IOException("Network session closed")); return; }
                }
                if (!result.complete(value)) value.close();
            }
        });
        return result;
    }
    static byte[] bounded(InputStream in) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] chunk=new byte[8192]; int n;
        while ((n=in.read(chunk)) != -1) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("Network request cancelled");
            if(bytes.size()+n>LIMIT) throw new IOException("Response body too large"); bytes.write(chunk,0,n);
        }
        return bytes.toByteArray();
    }
    public String cached(String key, String options, Callable<String> loader) throws Exception {
        open(); JSONObject o=new JSONObject(options); long ttl=o.getLong("ttl");
        if(ttl<0 || o.optBoolean("stale",false) || o.optBoolean("persist",false)) throw new UnsupportedOperationException("Unsupported cache policy");
        synchronized (cache) {
            Entry entry=cache.get(key);
            if(entry!=null && entry.expires>System.nanoTime()) return entry.value;
        }
        // Never hold the session lifecycle lock while payload code performs network I/O.
        String value=loader.call();
        synchronized (cache) {
            open();
            if(value!=null && value.length()<=LIMIT && ttl>0) {
                if(cache.size()>=128) cache.remove(cache.keySet().iterator().next());
                cache.put(key,new Entry(value,System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(Math.min(ttl,86_400_000))));
            }
        }
        return value;
    }
    @FunctionalInterface public interface Mapper<T,R> { R apply(T item, int index) throws Exception; }
    public <T,R> List<R> map(List<T> items, Mapper<T,R> mapper, int concurrency) throws Exception {
        open(); if(concurrency<1 || concurrency>32 || items.size()>10_000) throw new IllegalArgumentException("Invalid map bounds");
        List<R> out=new ArrayList<>(); List<Future<R>> pending=new ArrayList<>();
        try {
            for(int offset=0;offset<items.size();offset+=concurrency) {
                pending.clear();
                for(int i=offset;i<Math.min(items.size(),offset+concurrency);i++) { final int index=i; pending.add(ASYNC.submit(() -> { open(); return mapper.apply(items.get(index),index); })); }
                for(Future<R> f:pending) out.add(f.get());
            }
            return out;
        } finally { pending.forEach(f -> f.cancel(true)); }
    }
    public void close() {
        List<Net> owned; OkHttpClient old;
        synchronized(this) { if(closed)return; closed=true; owned=new ArrayList<>(children); children.clear(); old=client; }
        synchronized (cache) { cache.clear(); }
        owned.forEach(Net::close); calls.forEach(Call::cancel); streams.forEach(StreamResult::close); calls.clear();
        cookies.clear();
        if(old!=null) { old.dispatcher().executorService().shutdownNow(); old.connectionPool().evictAll(); }
        if(parent!=null) parent.children.remove(this);
    }
    private static final class Cookies implements CookieJar {
        private final List<Cookie> values=new ArrayList<>();
        public synchronized void saveFromResponse(HttpUrl url,List<Cookie> incoming) {
            for(Cookie cookie:incoming) { values.removeIf(c -> c.name().equals(cookie.name()) && c.domain().equals(cookie.domain()) && c.path().equals(cookie.path())); if(cookie.expiresAt()>System.currentTimeMillis()) values.add(cookie); }
            while(values.size()>256) values.remove(0);
        }
        public synchronized List<Cookie> loadForRequest(HttpUrl url) {
            values.removeIf(c -> c.expiresAt()<=System.currentTimeMillis());
            List<Cookie> out=new ArrayList<>(); for(Cookie c:values) if(c.matches(url)) out.add(c); return out;
        }
        synchronized void clear() { values.clear(); }
    }
    public static final class StreamResult extends InputStream {
        public final int code;
        public final Map<String,String> headers=new LinkedHashMap<>();
        public final String url;
        public final String contentType;
        private final Net owner; private final Call call; private final Response response; private final InputStream input;
        private boolean closed;
        StreamResult(Net owner,Call call,Response response) {
            this.owner=owner; this.call=call; this.response=response; code=response.code(); url=response.request().url().toString();
            contentType=response.header("Content-Type","application/octet-stream");
            for(String key:response.headers().names()) headers.put(key.toLowerCase(Locale.ROOT),String.join(key.equalsIgnoreCase("Set-Cookie")?"\n":", ",response.headers().values(key)));
            input=response.body()==null ? InputStream.nullInputStream() : response.body().byteStream();
        }
        java.nio.charset.Charset charset() { MediaType type=response.body()==null?null:response.body().contentType(); return type==null?StandardCharsets.UTF_8:type.charset(StandardCharsets.UTF_8); }
        public int read() throws IOException { return input.read(); }
        public int read(byte[] b,int off,int len) throws IOException { return input.read(b,off,len); }
        public synchronized void close() { if(closed)return; closed=true; response.close(); call.cancel(); owner.calls.remove(call); owner.streams.remove(this); }
    }
}
