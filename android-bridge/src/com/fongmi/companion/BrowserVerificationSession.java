package com.fongmi.companion;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.WebSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

final class BrowserVerificationSession implements AutoCloseable {
    private final String origin;
    private final Path profile;
    private final Process process;
    private final java.util.concurrent.ExecutorService executor;
    private final HttpClient client;
    private Cdp cdp;
    private boolean verified;
    private boolean closed;
    private String userAgent;

    private BrowserVerificationSession(URI page, Path profile, Process process) {
        origin = BrowserChallenge.origin(page); this.profile = profile; this.process = process;
        executor = Executors.newFixedThreadPool(2, r -> { Thread t=new Thread(r,"browser-verification-http");t.setDaemon(true);return t; });
        client = HttpClient.newBuilder().executor(executor).connectTimeout(Duration.ofSeconds(3)).proxy(new ProxySelector() {
            @Override public List<Proxy> select(URI uri) { return List.of(Proxy.NO_PROXY); }
            @Override public void connectFailed(URI uri, SocketAddress address, IOException error) { }
        }).build();
    }

    static BrowserVerificationSession open(URI page, String proxySpec) throws IOException {
        BrowserChallenge.httpUrl(page);
        Path executable = executable();
        String proxyArgument = null;
        if (proxySpec != null && !proxySpec.isBlank()) {
            Proxy proxy = FallbackProxySelector.parse(proxySpec);
            if (proxy == null) throw new IOException("Invalid verification proxy configuration");
            InetSocketAddress address = (InetSocketAddress)proxy.address();
            String host = address.getHostString();
            if (!host.matches("[a-zA-Z0-9_.:\\[\\]-]+")) throw new IOException("Invalid verification proxy host");
            proxyArgument = "--proxy-server=http://" + host + ":" + address.getPort();
        }
        Path profile = Files.createTempDirectory("xiugou-verification-").toRealPath();
        List<String> command = new ArrayList<>(List.of(executable.toString(), "--user-data-dir=" + profile, "--remote-debugging-port=0",
                "--no-first-run", "--no-default-browser-check", "--app=" + page.toASCIIString()));
        if (proxyArgument != null) command.add(proxyArgument);
        Process process;
        try { process = new ProcessBuilder(command).redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD).start(); }
        catch (IOException error) { deleteProfile(profile); throw new IOException("Unable to open the verification browser"); }
        BrowserVerificationSession session = new BrowserVerificationSession(page, profile, process);
        try { session.connect(); return session; }
        catch (IOException error) { session.close(); throw error; }
    }

    private static Path executable() throws IOException {
        List<String> roots = new ArrayList<>();
        String override = System.getProperty("xiugou.browser.executable", "");
        if (!override.isBlank()) { Path candidate=Path.of(override);if(Files.isRegularFile(candidate))return candidate;throw new IOException("Verification browser executable is unavailable"); }
        for(String name:List.of("ProgramFiles(x86)","ProgramFiles","LOCALAPPDATA")) {
            String value=System.getenv(name);if(value!=null&&!value.isBlank())roots.add(value);
        }
        for(String root:roots)for(String suffix:List.of("Microsoft/Edge/Application/msedge.exe","Google/Chrome/Application/chrome.exe")) {
            Path candidate=Path.of(root).resolve(suffix);if(Files.isRegularFile(candidate))return candidate;
        }
        throw new IOException("Install Microsoft Edge or Chrome to complete website verification");
    }

    private void connect() throws IOException {
        long until=System.nanoTime()+TimeUnit.SECONDS.toNanos(15);
        Path active=profile.resolve("DevToolsActivePort");
        int port=0;
        while(System.nanoTime()<until) {
            if(Files.isRegularFile(active))try { port=Integer.parseInt(Files.readAllLines(active).get(0));if(port>0&&port<=65535)break; }catch(RuntimeException ignored) { }
            pause();
        }
        if(port<=0||port>65535)throw new IOException("Verification browser did not become ready");
        URI target=null;
        while(System.nanoTime()<until && target==null) {
            try {
                var response=client.send(HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+"/json/list")).timeout(Duration.ofSeconds(2)).build(),HttpResponse.BodyHandlers.ofString());
                if(response.body().length()>256*1024)throw new IOException("Invalid verification browser response");
                Object parsed=JsonCodec.parse(response.body());
                if(parsed instanceof List<?> pages)for(Object raw:pages) {
                    Map<String,Object> page=obj(raw);
                    if(!"page".equals(page.get("type")))continue;
                    String value=String.valueOf(page.getOrDefault("url",""));
                    if(value.startsWith("http") && origin.equals(BrowserChallenge.origin(URI.create(value)))) {
                        URI ws=URI.create(String.valueOf(page.get("webSocketDebuggerUrl")));
                        if(!"ws".equals(ws.getScheme()) || !"127.0.0.1".equals(ws.getHost()) || ws.getPort()!=port)throw new IOException("Invalid verification debugger endpoint");
                        target=ws;break;
                    }
                }
            } catch(InterruptedException interrupted) { Thread.currentThread().interrupt();throw new IOException("Verification canceled"); }
            catch(RuntimeException ignored) { }
            if(target==null)pause();
        }
        if(target==null)throw new IOException("Verification window is closed or unavailable");
        cdp=new Cdp(client,target);
        cdp.command("Page.enable",Map.of(),3000);
        userAgent=String.valueOf(cdp.value("navigator.userAgent",3000));
    }

    private static void pause() throws IOException {
        try { Thread.sleep(40); }catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException("Verification canceled");}
    }

    boolean verified() { return verified && !closed && cdp!=null && cdp.connected(); }
    String userAgent() { return userAgent; }
    void invalidate() { verified=false; }
    boolean complete(URI url, long timeoutMs) throws IOException {
        Map<String,Object> response=request(url,Map.of("method","GET"),timeoutMs);
        int code=((Number)response.getOrDefault("code",0)).intValue();
        verified=((code>=200&&code<400)||code==405)&&!BrowserChallenge.detected(response);
        return verified;
    }
    void navigate(URI page) throws IOException {
        if(!origin.equals(BrowserChallenge.origin(page)))throw new IOException("Verification navigation changed origin");
        verified=false;
        cdp.command("Page.navigate",Map.of("url",page.toASCIIString()),5000);
    }

    Map<String, String> playbackHeaders(URI media, long timeoutMs) throws IOException {
        if (!verified() || !origin.equals(BrowserChallenge.origin(media))) return Map.of();
        Map<String, Object> reply = cdp.command("Network.getCookies", Map.of("urls", List.of(media.toASCIIString())), Math.min(3000, Math.max(1, timeoutMs)));
        List<String> cookies = new ArrayList<>();
        if (reply.get("cookies") instanceof List<?> values) for (Object raw : values) {
            Map<String, Object> cookie = obj(raw);
            String name = String.valueOf(cookie.getOrDefault("name", ""));
            String value = String.valueOf(cookie.getOrDefault("value", ""));
            if (name.matches("[a-zA-Z0-9_!#$%&'*+.^`|~-]+") && !value.contains("\r") && !value.contains("\n") && !value.contains(";")) cookies.add(name + "=" + value);
        }
        String header = String.join("; ", cookies);
        if (header.length() > 16384) throw new IOException("Verification cookie header exceeds limit");
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("User-Agent", userAgent);
        if (!header.isBlank()) headers.put("Cookie", header);
        return headers;
    }

    Map<String,Object> request(URI url, Map<String,Object> options, long timeoutMs) throws IOException {
        if(closed||cdp==null||!cdp.connected())throw new IOException("Verification window has closed");
        if(!origin.equals(BrowserChallenge.origin(url)))throw new IOException("Verification session is limited to one origin");
        String method=String.valueOf(options.getOrDefault("method","GET")).toUpperCase(Locale.ROOT);
        if(!List.of("GET","POST","HEAD").contains(method))throw new IOException("Unsupported browser request method");
        Map<String,String> headers=new LinkedHashMap<>();
        if(options.get("headers") instanceof Map<?,?> raw)for(var entry:raw.entrySet()) {
            String key=String.valueOf(entry.getKey());String lower=key.toLowerCase(Locale.ROOT);
            if(List.of("cookie","host","user-agent","referer","origin","content-length","connection","accept-encoding").contains(lower)||lower.startsWith("sec-")||lower.startsWith("proxy-"))continue;
            headers.put(key,String.valueOf(entry.getValue()));
        }
        Map<String,Object> init=new LinkedHashMap<>();
        init.put("method",method);init.put("headers",headers);init.put("credentials","include");init.put("redirect","error");
        if(options.containsKey("body")&&!method.equals("GET")&&!method.equals("HEAD"))init.put("body",String.valueOf(options.get("body")));
        long budget=Math.min(20000,Math.max(1,timeoutMs));
        String expression="(async()=>{const u=new URL("+JsonCodec.stringify(url.toASCIIString())+");if(location.origin!==u.origin)throw Error('origin');"
                +"const abort=new AbortController();const timer=setTimeout(()=>abort.abort(),"+budget+");try{const options="+JsonCodec.stringify(init)+";options.signal=abort.signal;const r=await fetch(u.href,options);"
                +"const type=r.headers.get('content-type')||'text/plain';if(!/^(?:text\\/|application\\/(?:json|javascript|xhtml\\+xml|ld\\+json|x-javascript))/.test(type)){await r.body?.cancel();throw Error('not text');}"
                +"const reader=r.body?.getReader();let n=0,parts=[];if(reader){try{for(;;){const x=await reader.read();if(x.done)break;n+=x.value.length;if(n>8388608)throw Error('text limit');parts.push(x.value);}}finally{await reader.cancel();}}"
                +"const bytes=new Uint8Array(n);let p=0;for(const part of parts){bytes.set(part,p);p+=part.length;}"
                +"return {code:r.status,url:r.url,headers:Object.fromEntries(r.headers),content:new TextDecoder().decode(bytes)};}finally{clearTimeout(timer);}})()";
        Object result=cdp.value(expression,budget);
        Map<String,Object> response=obj(result);
        if(!response.containsKey("code")||!response.containsKey("content"))throw new IOException("Invalid verification text response");
        URI finalUrl=BrowserChallenge.httpUrl(URI.create(String.valueOf(response.get("url"))));
        if(!origin.equals(BrowserChallenge.origin(finalUrl)))throw new IOException("Browser response changed origin");
        return response;
    }

    @Override public void close() {
        if(closed)return;closed=true;verified=false;
        if(cdp!=null){try{cdp.command("Browser.close",Map.of(),500);}catch(IOException ignored){}cdp.close();}
        List<ProcessHandle> descendants=process.descendants().toList();
        process.destroy();for(var child:descendants)child.destroy();
        try{if(!process.waitFor(700,TimeUnit.MILLISECONDS))process.destroyForcibly();}catch(InterruptedException interrupted){Thread.currentThread().interrupt();process.destroyForcibly();}
        for(var child:descendants)if(child.isAlive())child.destroyForcibly();
        client.shutdownNow();executor.shutdownNow();deleteProfile(profile);
    }
    private static void deleteProfile(Path profile) {
        if(!profile.getFileName().toString().startsWith("xiugou-verification-"))return;
        try(var files=Files.walk(profile)){for(Path file:files.sorted(Comparator.reverseOrder()).toList())try{Files.deleteIfExists(file);}catch(IOException ignored){}}
        catch(IOException ignored) { }
    }
    @SuppressWarnings("unchecked") private static Map<String,Object> obj(Object raw) {return raw instanceof Map<?,?>?(Map<String,Object>)raw:Map.of();}

    private static final class Cdp implements WebSocket.Listener, AutoCloseable {
        private final AtomicInteger sequence=new AtomicInteger();
        private final Map<Integer,CompletableFuture<Map<String,Object>>> pending=new ConcurrentHashMap<>();
        private final StringBuilder incoming=new StringBuilder();
        private volatile WebSocket socket;
        private volatile boolean ended;
        Cdp(HttpClient client,URI endpoint)throws IOException {
            try{socket=client.newWebSocketBuilder().connectTimeout(Duration.ofSeconds(3)).buildAsync(endpoint,this).get(4,TimeUnit.SECONDS);}
            catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException("Verification connection canceled");}
            catch(Exception error){throw new IOException("Cannot connect to the verification window");}
        }
        boolean connected(){return !ended&&socket!=null&&!socket.isInputClosed()&&!socket.isOutputClosed();}
        @Override public void onOpen(WebSocket socket){socket.request(1);}
        @Override public CompletionStage<?> onText(WebSocket socket,CharSequence data,boolean last){
            synchronized(incoming){
                if(incoming.length()+data.length()>12*1024*1024){close();return null;}
                incoming.append(data);
                if(last){
                    try{Map<String,Object> reply=JsonCodec.parseObject(incoming.toString());Object raw=reply.get("id");if(raw instanceof Number number){var wait=pending.remove(number.intValue());if(wait!=null)wait.complete(reply);}}
                    catch(RuntimeException ignored){}finally{incoming.setLength(0);}
                }
            }
            socket.request(1);return null;
        }
        @Override public CompletionStage<?> onClose(WebSocket socket,int status,String reason){close();return null;}
        @Override public void onError(WebSocket socket,Throwable error){close();}
        Map<String,Object> command(String method,Map<String,Object> parameters,long timeoutMs)throws IOException {
            if(!connected())throw new IOException("Verification window has closed");
            int id=sequence.incrementAndGet();CompletableFuture<Map<String,Object>> result=new CompletableFuture<>();pending.put(id,result);
            try{
                socket.sendText(JsonCodec.stringify(Map.of("id",id,"method",method,"params",parameters)),true).get(timeoutMs,TimeUnit.MILLISECONDS);
                Map<String,Object> reply=result.get(timeoutMs,TimeUnit.MILLISECONDS);
                if(reply.containsKey("error"))throw new IOException("Verification browser command failed");
                return obj(reply.get("result"));
            }catch(InterruptedException interrupted){terminateEvaluation();Thread.currentThread().interrupt();throw new IOException("Verification canceled");}
            catch(IOException error){throw error;}
            catch(Exception error){terminateEvaluation();throw new IOException("Verification browser request timed out or was canceled");}
            finally{pending.remove(id);}
        }
        private void terminateEvaluation() {
            WebSocket active=socket;
            if(active!=null&&!ended)active.sendText(JsonCodec.stringify(Map.of("id",sequence.incrementAndGet(),"method","Runtime.terminateExecution","params",Map.of())),true);
        }
        Object value(String expression,long timeoutMs)throws IOException {
            Map<String,Object> reply=command("Runtime.evaluate",Map.of("expression",expression,"awaitPromise",true,"returnByValue",true),timeoutMs);
            if(reply.containsKey("exceptionDetails"))throw new IOException("Verification page is not ready or the request failed");
            return obj(reply.get("result")).get("value");
        }
        @Override public void close(){ended=true;WebSocket active=socket;if(active!=null)active.abort();for(var value:pending.values())value.completeExceptionally(new IOException("Verification window closed"));pending.clear();}
    }
}
