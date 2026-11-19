package com.fongmi.companion;

import com.github.catvod.crawler.Spider;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;

/** Capabilities belong to exact live objects, never to a caller-supplied site key or jar. */
public final class JavaProxyRegistry implements AutoCloseable {
    private final Map<String,Binding> tokens=new HashMap<>();
    private final Map<Spider,Binding> instances=new IdentityHashMap<>();
    private String base="";
    public synchronized void setBase(String base) { this.base=base; }
    public synchronized void bind(Spider spider) {
        byte[] random=new byte[24]; new SecureRandom().nextBytes(random);
        String token=Base64.getUrlEncoder().withoutPadding().encodeToString(random);
        Binding binding=new Binding(spider); instances.put(spider,binding); tokens.put(token,binding);
        spider.bindHostProxy(params -> url(token,binding,params));
    }
    public synchronized void activate(Spider spider) { Binding b=instances.get(spider); if(b==null)throw new IllegalStateException("Spider released"); b.active=true; }
    private synchronized String url(String token,Binding binding,Map<String,String> params) {
        if(tokens.get(token)!=binding || base.isEmpty()) throw new IllegalStateException("Spider proxy unavailable");
        StringBuilder url=new StringBuilder(base).append('/').append(token); boolean first=true;
        if(params!=null) for(var p:params.entrySet()) {
            url.append(first?'?':'&'); first=false;
            url.append(URLEncoder.encode(p.getKey(),StandardCharsets.UTF_8)).append('=')
                    .append(URLEncoder.encode(Objects.toString(p.getValue(),""),StandardCharsets.UTF_8));
        }
        return url.toString();
    }
    public synchronized Binding lookup(String token) { Binding b=tokens.get(token); return b!=null && b.active?b:null; }
    public void remove(Spider spider) {
        Binding old;
        synchronized(this) { old=instances.remove(spider); if(old!=null) tokens.values().removeIf(b -> b==old); }
        if(old!=null) old.close();
    }
    /** Revoke under the loader lock; close payload streams after releasing that lock. */
    public synchronized Runnable revokeAll() {
        List<Runnable> releases=new ArrayList<>();
        for(Binding binding:instances.values()) releases.add(binding.revoke());
        instances.clear(); tokens.clear();
        return () -> releases.forEach(Runnable::run);
    }
    public void close() { revokeAll().run(); }
    public static final class Binding implements AutoCloseable {
        final Spider spider;
        private boolean active,closed;
        private final Set<AutoCloseable> pending=new HashSet<>();
        Binding(Spider spider) { this.spider=spider; }
        synchronized boolean own(AutoCloseable request) { if(closed)return false; pending.add(request); return true; }
        synchronized void release(AutoCloseable request) { pending.remove(request); }
        synchronized boolean live() { return !closed; }
        synchronized Runnable revoke() {
            if(closed)return () -> {};
            closed=true;
            List<AutoCloseable> old=new ArrayList<>(pending); pending.clear();
            return () -> { for(AutoCloseable request:old) try { request.close(); } catch(Exception ignored) {} };
        }
        public void close() { revoke().run(); }
    }
}
