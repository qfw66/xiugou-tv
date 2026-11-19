package com.fongmi.companion;

import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Same-origin loopback HTTP transport for registered Java Spider.proxy(Map) instances. */
public final class JavaProxyHandler implements HttpHandler {
    public static final String PREFIX="/java-proxy";
    private static final int BODY_LIMIT=1024*1024;
    /** Only a real HTTP header may authenticate the payload; body and query fields must not. */
    private static final String SETTINGS_HEADER="x-catvod-settings", FORM_TYPE="application/x-www-form-urlencoded";
    private static final Set<String> HOP=Set.of("connection","keep-alive","proxy-authenticate","proxy-authorization","te","trailer","transfer-encoding","upgrade");
    private static final ScheduledExecutorService TIMER=Executors.newScheduledThreadPool(2,r -> { Thread t=new Thread(r,"java-proxy-deadline"); t.setDaemon(true); return t; });
    private final JavaProxyRegistry registry;
    private final ExecutorService workers;
    public JavaProxyHandler(JavaProxyRegistry registry,ExecutorService workers) { this.registry=registry; this.workers=workers; }
    public void handle(HttpExchange exchange) throws IOException {
        ProxyCall call=null; JavaProxyRegistry.Binding binding=null; ScheduledFuture<?> timer=null;
        boolean streaming=false,completed=false;
        try {
            String host=exchange.getRequestHeaders().getFirst("Host");
            String authority="127.0.0.1:"+exchange.getLocalAddress().getPort();
            String origin=exchange.getRequestHeaders().getFirst("Origin");
            if(!exchange.getRemoteAddress().getAddress().isLoopbackAddress() || !authority.equalsIgnoreCase(host)
                    || (origin!=null && !("http://"+authority).equals(origin))) { error(exchange,403); return; }
            String path=exchange.getRequestURI().getRawPath();
            if(!path.startsWith(PREFIX+"/") || path.length()!=PREFIX.length()+33) { error(exchange,404); return; }
            binding=registry.lookup(path.substring(PREFIX.length()+1));
            if(binding==null) { error(exchange,404); return; }
            if(exchange.getRequestURI().getRawQuery()!=null && exchange.getRequestURI().getRawQuery().length()>256*1024) { error(exchange,414); return; }
            call=new ProxyCall(binding,exchange); if(!binding.own(call)) { error(exchange,404); return; }
            ProxyCall owned=call;
            long timeout=Math.max(1,Math.min(30_000,Long.getLong("xiugou.java.proxyTimeoutMs",30_000)));
            timer=TIMER.schedule(owned::close,timeout,TimeUnit.MILLISECONDS);
            String declared=exchange.getRequestHeaders().getFirst("Content-Length");
            if(declared!=null && Long.parseLong(declared)>BODY_LIMIT) { error(exchange,413); return; }
            byte[] body=read(exchange.getRequestBody(),BODY_LIMIT);
            Map<String,String> params=query(exchange.getRequestURI().getRawQuery());
            // Configuration pages save with a form POST; NanoHTTPD merges that body into its parameter
            // map after the query string, so a form value wins when body and query carry the same name.
            params.putAll(form(body,exchange.getRequestHeaders().getFirst("Content-Type")));
            params.remove(SETTINGS_HEADER); // Authentication must come from the real HTTP header.
            Map<String,String> headers=new LinkedHashMap<>();
            exchange.getRequestHeaders().forEach((key,values) -> headers.put(key.toLowerCase(Locale.ROOT),String.join(", ",values)));
            headers.forEach(params::put);
            params.put("headers",JsonCodec.stringify(headers)); params.put("method",exchange.getRequestMethod());
            params.put("body",new String(body,StandardCharsets.UTF_8));
            params.put("bodyBase64",Base64.getEncoder().encodeToString(body));
            Future<Object[]> pending=workers.submit(() -> owned.invoke(params)); call.pending(pending);
            Object[] response=pending.get(timeout,TimeUnit.MILLISECONDS);
            if(!binding.live()) { error(exchange,404); return; }
            if(response==null) { error(exchange,404); return; }
            if(response.length<3 || !(response[0] instanceof Number)) throw new IOException("Invalid proxy response");
            int status=((Number)response[0]).intValue(); if(status<200 || status>599)throw new IOException("Invalid status");
            String mime=Objects.toString(response[1],"application/octet-stream");
            Map<?,?> resultHeaders=response.length>3 && response[3] instanceof Map<?,?> map?map:Map.of();
            Set<String> forbidden=new HashSet<>(HOP);
            resultHeaders.forEach((key,value) -> { if("connection".equalsIgnoreCase(String.valueOf(key))) for(String named:String.valueOf(value).split(","))forbidden.add(named.trim().toLowerCase(Locale.ROOT)); });
            resultHeaders.forEach((key,value) -> {
                String name=String.valueOf(key),lower=name.toLowerCase(Locale.ROOT);
                if(forbidden.contains(lower) || lower.equals("content-length") || lower.equals("content-type") || lower.startsWith("access-control-"))return;
                if(value instanceof Iterable<?> values) for(Object item:values) addHeader(exchange,name,String.valueOf(item));
                else addHeader(exchange,name,String.valueOf(value));
            });
            addHeader(exchange,"Content-Type",mime);
            exchange.getResponseHeaders().set("Referrer-Policy","no-referrer");
            exchange.getResponseHeaders().set("X-Content-Type-Options","nosniff");
            exchange.getResponseHeaders().putIfAbsent("Cache-Control",List.of("no-store"));
            InputStream input;
            boolean head=exchange.getRequestMethod().equals("HEAD"), noEntity=status==204 || status==304;
            long length=responseLength(resultHeaders,forbidden), knownLength=-1;
            if(response[2] instanceof InputStream stream) input=stream;
            else if(response[2] instanceof byte[] bytes) { input=new ByteArrayInputStream(bytes); knownLength=bytes.length; }
            else if(response[2] instanceof String text) {
                byte[] bytes=text.getBytes(StandardCharsets.UTF_8); input=new ByteArrayInputStream(bytes); knownLength=bytes.length;
            } else if(response[2]==null) { input=InputStream.nullInputStream(); knownLength=0; }
            else throw new IOException("Unsupported proxy body");
            if(knownLength>=0) {
                if(!head && !noEntity && length>=0 && length!=knownLength)throw new IOException("Conflicting proxy length");
                if(length<0 && status!=304)length=knownLength;
            }
            timer.cancel(false); timer=null;
            if(status!=204 && length>=0) exchange.getResponseHeaders().set("Content-Length",Long.toString(length));
            try(StreamDeadline deadline=new StreamDeadline(owned)) {
                if(head || noEntity || length==0) {
                    deadline.write(() -> exchange.sendResponseHeaders(status,-1));
                } else {
                    streaming=true;
                    long responseLength=Math.max(0,length);
                    deadline.write(() -> exchange.sendResponseHeaders(status,responseLength));
                    byte[] chunk=new byte[65536];
                    long remaining=length;
                    while(remaining!=0) {
                        int count=deadline.read(input,chunk,remaining<0?chunk.length:(int)Math.min(chunk.length,remaining));
                        if(count<0) { if(remaining>0)throw new EOFException("Incomplete proxy body"); break; }
                        if(count==0)throw new IOException("Proxy stream made no progress");
                        deadline.write(() -> { exchange.getResponseBody().write(chunk,0,count); exchange.getResponseBody().flush(); });
                        if(remaining>0)remaining-=count;
                    }
                    deadline.write(() -> exchange.getResponseBody().close());
                }
            }
            completed=true;
        } catch(BadRequest e) { if(exchange.getResponseCode()==-1)error(exchange,400); }
        catch(TooLarge e) { if(exchange.getResponseCode()==-1)error(exchange,413); }
        catch(RejectedExecutionException e) { if(exchange.getResponseCode()==-1)error(exchange,503); }
        catch(Exception e) {
            if(e instanceof InterruptedException)Thread.currentThread().interrupt();
            // Exceptions can include URL capabilities or credentials: never log or echo them.
            if(exchange.getResponseCode()==-1) try { error(exchange,e instanceof TimeoutException?504:502); } catch(IOException ignored) {}
        } finally {
            if(timer!=null)timer.cancel(false);
            boolean abort=streaming && !completed, interrupted=Thread.currentThread().isInterrupted();
            // An interrupted channel close aborts chunked transfer instead of sending a false EOF.
            if(abort)Thread.currentThread().interrupt();
            try {
                if(call!=null) { call.close(); if(binding!=null)binding.release(call); }
                exchange.close();
            } finally {
                if((abort && !interrupted) || (call!=null && call.cancelled))Thread.interrupted();
            }
        }
    }
    private static long responseLength(Map<?,?> headers,Set<String> forbidden)throws IOException {
        if(forbidden.contains("content-length"))return -1;
        long length=-1;
        for(var header:headers.entrySet()) {
            if(!"content-length".equalsIgnoreCase(String.valueOf(header.getKey())))continue;
            Iterable<?> values=header.getValue() instanceof Iterable<?> items?items:Collections.singletonList(header.getValue());
            for(Object item:values) {
                String value=String.valueOf(item);
                if(!value.matches("[0-9]+"))throw new IOException("Invalid proxy length");
                long parsed;
                try { parsed=Long.parseLong(value); } catch(NumberFormatException e) { throw new IOException("Invalid proxy length"); }
                if(length>=0 && length!=parsed)throw new IOException("Conflicting proxy length");
                length=parsed;
            }
        }
        return length;
    }
    private static void addHeader(HttpExchange exchange,String name,String value) {
        if(!name.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+") || value.indexOf('\r')>=0 || value.indexOf('\n')>=0)throw new IllegalArgumentException("Invalid response header");
        exchange.getResponseHeaders().add(name,value);
    }
    static Map<String,String> query(String text) { return pairs(text); }
    /**
     * application/x-www-form-urlencoded bodies only. JSON, multipart and binary bodies keep their raw
     * {@code body}/{@code bodyBase64} fields and are never guessed into parameters from their shape.
     */
    static Map<String,String> form(byte[] body,String contentType) {
        if(body.length==0 || !FORM_TYPE.equals(mime(contentType))) return new LinkedHashMap<>();
        return pairs(new String(body,StandardCharsets.ISO_8859_1)); // byte-preserving: decoding happens in decode()
    }
    /** Media type without parameters, case-insensitive: {@code Application/X-WWW-Form-URLEncoded; charset=UTF-8}. */
    private static String mime(String contentType) {
        if(contentType==null)return "";
        int semicolon=contentType.indexOf(';');
        return (semicolon<0?contentType:contentType.substring(0,semicolon)).trim().toLowerCase(Locale.ROOT);
    }
    private static Map<String,String> pairs(String text) {
        Map<String,String> out=new LinkedHashMap<>(); if(text==null)return out;
        for(String pair:text.split("&")) {
            int equal=pair.indexOf('=');
            out.put(decode(equal<0?pair:pair.substring(0,equal)),decode(equal<0?"":pair.substring(equal+1)));
        }
        return out;
    }
    /** '+' is a space, escapes are bytes, and those bytes must decode as strict UTF-8. */
    private static String decode(String text) {
        ByteArrayOutputStream out=new ByteArrayOutputStream(text.length());
        for(int i=0;i<text.length();i++) {
            char c=text.charAt(i);
            if(c=='+') out.write(' ');
            else if(c=='%') {
                if(i+2>=text.length()) throw new BadRequest();
                int hi=hex(text.charAt(i+1)),lo=hex(text.charAt(i+2));
                if(hi<0 || lo<0) throw new BadRequest();
                out.write((hi<<4)|lo); i+=2;
            }
            else if(c<0x100) out.write(c);
            else { byte[] extra=String.valueOf(c).getBytes(StandardCharsets.UTF_8); out.write(extra,0,extra.length); }
        }
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(out.toByteArray())).toString();
        } catch(CharacterCodingException e) { throw new BadRequest(); }
    }
    private static int hex(char c) {
        if(c>='0' && c<='9')return c-'0';
        if(c>='a' && c<='f')return c-'a'+10;
        if(c>='A' && c<='F')return c-'A'+10;
        return -1;
    }
    /** Malformed percent/UTF-8 encoding is the caller's fault: answer 400, never 502. */
    private static final class BadRequest extends RuntimeException {}
    private static final class TooLarge extends IOException {}
    private static byte[] read(InputStream in,int limit) throws IOException {
        ByteArrayOutputStream out=new ByteArrayOutputStream(); byte[] chunk=new byte[8192]; int n;
        while((n=in.read(chunk))!=-1) { if(out.size()+n>limit)throw new TooLarge(); out.write(chunk,0,n); } return out.toByteArray();
    }
    private static void error(HttpExchange e,int code)throws IOException { e.getResponseHeaders().set("Cache-Control","no-store"); e.sendResponseHeaders(code,-1); }
    private static final class StreamDeadline implements AutoCloseable {
        private final ProxyCall call;
        private final Thread owner=Thread.currentThread();
        private final long timeout=Math.max(1,Math.min(30_000,Long.getLong("xiugou.java.streamIdleTimeoutMs",30_000)));
        private final ScheduledFuture<?> timer;
        private long started;
        private boolean closed,expired;
        StreamDeadline(ProxyCall call) {
            this.call=call;
            long interval=Math.max(1,Math.min(250,timeout/4));
            timer=TIMER.scheduleWithFixedDelay(this::check,interval,interval,TimeUnit.MILLISECONDS);
        }
        private void check() {
            synchronized(this) {
                if(closed || expired || started==0 || System.nanoTime()-started<TimeUnit.MILLISECONDS.toNanos(timeout))return;
                expired=true;
                // The lifetime lock prevents a late interrupt from reaching the next HTTP request.
                owner.interrupt();
            }
            call.close();
        }
        private synchronized void begin()throws IOException {
            if(expired)throw new InterruptedIOException("Proxy stream idle timeout");
            started=System.nanoTime();
        }
        private synchronized void end(){started=0;}
        int read(InputStream input,byte[] bytes,int length)throws IOException {
            begin();try{return input.read(bytes,0,length);}finally{end();}
        }
        void write(IoAction action)throws IOException {begin();try{action.run();}finally{end();}}
        @Override public synchronized void close() {
            closed=true;timer.cancel(false);if(expired)Thread.interrupted();
        }
    }
    private interface IoAction {void run()throws IOException;}
    private static final class ProxyCall implements AutoCloseable {
        final JavaProxyRegistry.Binding binding; final HttpExchange exchange;
        private final Thread owner=Thread.currentThread();
        private volatile boolean cancelled;
        private Object[] response; private Future<?> pending; private boolean closed;
        ProxyCall(JavaProxyRegistry.Binding binding,HttpExchange exchange) { this.binding=binding; this.exchange=exchange; }
        synchronized void pending(Future<?> future) { pending=future; if(closed)future.cancel(true); }
        Object[] invoke(Map<String,String> params)throws Exception {
            synchronized(this) { if(closed)throw new IOException("Proxy cancelled"); }
            Object[] value=binding.spider.proxy(params);
            synchronized(this) { if(!closed) { response=value; return value; } }
            dispose(value); throw new IOException("Proxy cancelled");
        }
        private static void dispose(Object[] value) { if(value!=null && value.length>2 && value[2] instanceof AutoCloseable body)try { body.close(); }catch(Exception ignored){} }
        public void close() {
            Object[] owned; Future<?> job; boolean external,committed;
            synchronized(this) {
                if(closed)return; closed=true; owned=response; response=null; job=pending;
                external=Thread.currentThread()!=owner; committed=exchange.getResponseCode()!=-1;
                if(external && committed) { cancelled=true; owner.interrupt(); }
            }
            if(job!=null)job.cancel(true);
            if(!external || !committed)exchange.close();
            dispose(owned);
        }
    }
}
