package com.fongmi.companion;

import java.io.IOException;
import java.io.InputStream;
import java.net.ConnectException;
import java.net.NoRouteToHostException;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.SocketException;
import java.net.URI;
import java.net.UnknownHostException;
import java.net.http.HttpClient;
import java.net.http.HttpConnectTimeoutException;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.security.cert.CertificateException;
import java.security.cert.CertPathValidatorException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLHandshakeException;
import javax.net.ssl.SSLPeerUnverifiedException;

/** Executes the configured script-host proxy routes; JDK HttpClient uses only one selector result. */
final class ScriptHttpTransport {
    private final HttpClient.Redirect redirect;
    private final SSLContext sslContext;
    private final Map<Proxy, HttpClient> clients = new LinkedHashMap<>(4, 0.75f, true);

    ScriptHttpTransport(HttpClient.Redirect redirect, SSLContext sslContext) {
        this.redirect = redirect;
        this.sslContext = sslContext;
    }

    HttpResponse<InputStream> send(HttpRequest request) throws IOException, InterruptedException {
        URI uri = request.uri();
        ProxySelector selector = ProxySelector.getDefault();
        List<Proxy> routes = new ArrayList<>();
        if (selector != null && !FallbackProxySelector.isLocal(uri.getHost())) {
            List<Proxy> selected = selector.select(uri);
            if (selected != null) for (Proxy route : selected) {
                if (route != null && route.type() != Proxy.Type.SOCKS && !routes.contains(route)) routes.add(route);
            }
        }
        if (routes.isEmpty()) routes.add(Proxy.NO_PROXY);
        IOException first = null;
        for (int index = 0; index < Math.min(2, routes.size()); index++) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException("Script HTTP request canceled");
            Proxy route = routes.get(index);
            try {
                return client(route).send(request, HttpResponse.BodyHandlers.ofInputStream());
            } catch (IOException error) {
                if (first == null) first = error;
                else first.addSuppressed(error);
                if (!canRetry(request.method(), error) || index == 1) throw first;
            }
        }
        throw first;
    }

    private synchronized HttpClient client(Proxy route) {
        HttpClient existing = clients.get(route);
        if (existing != null) return existing;
        HttpClient.Builder builder = HttpClient.newBuilder()
                .followRedirects(redirect)
                .connectTimeout(Duration.ofSeconds(15))
                .proxy(new ProxySelector() {
                    @Override public List<Proxy> select(URI uri) {
                        return List.of(FallbackProxySelector.isLocal(uri.getHost()) ? Proxy.NO_PROXY : route);
                    }
                    @Override public void connectFailed(URI uri, SocketAddress address, IOException error) {}
                });
        if (sslContext != null) builder.sslContext(sslContext);
        HttpClient created = builder.build();
        if (clients.size() >= 4) {
            var oldest = clients.entrySet().iterator();
            HttpClient retired = oldest.next().getValue();
            oldest.remove();
            retired.shutdown();
        }
        clients.put(route, created);
        return created;
    }

    private static boolean canRetry(String method, IOException error) {
        boolean connectionFailure = false;
        boolean safeRead = method.equalsIgnoreCase("GET") || method.equalsIgnoreCase("HEAD");
        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
            if (cause instanceof CertificateException || cause instanceof CertPathValidatorException
                    || cause instanceof SSLPeerUnverifiedException) return false;
            String message = String.valueOf(cause.getMessage()).toLowerCase(java.util.Locale.ROOT);
            if (message.contains("pkix") || message.contains("certificate_verify_failed")
                    || message.contains("subject alternative") || message.contains("no name matching")) return false;
            if (cause instanceof ConnectException || cause instanceof UnknownHostException
                    || cause instanceof NoRouteToHostException || cause instanceof HttpConnectTimeoutException
                    || cause instanceof SSLHandshakeException
                    || safeRead && (cause instanceof SocketException || cause instanceof HttpTimeoutException)) {
                connectionFailure = true;
            }
        }
        return connectionFailure && !Thread.currentThread().isInterrupted();
    }
}
