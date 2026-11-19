package com.fongmi.companion;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;

/** Stages the source and its two standard DZ libraries without writing to the source directory. */
final class PhpSource {
    private static final int MAX_SOURCE = 8 * 1024 * 1024;

    static boolean matches(String api) {
        if (api == null) return false;
        String path = api.trim().split("[?#]", 2)[0].toLowerCase(Locale.ROOT);
        return path.endsWith(".php");
    }

    static Path prepare(String api, String identity, File cache) throws Exception {
        String location = com.fongmi.companion.py.PyRuntime.normalizeScriptUrl(api);
        URI uri;
        if (location.startsWith("http://") || location.startsWith("https://")) {
            okhttp3.HttpUrl address = okhttp3.HttpUrl.parse(location);
            if (address == null) throw new IOException("PHP 源地址无效");
            uri = address.uri();
        } else if (location.startsWith("file:")) {
            uri = URI.create(location.replace(" ", "%20"));
        } else {
            uri = Path.of(location).toAbsolutePath().toUri();
        }
        if (!Set.of("http", "https", "file").contains(uri.getScheme())) throw new IOException("PHP 源地址协议不支持");
        String name = uri.getPath().substring(uri.getPath().lastIndexOf('/') + 1).replaceAll("[\\\\/:*?\"<>|]", "_");
        Path dir = cache.toPath().resolve("php").resolve(hash(identity));
        Map<String, byte[]> files = new LinkedHashMap<>();
        byte[] entry = read(uri);
        files.put(name, entry);
        String code = new String(entry, StandardCharsets.UTF_8);
        if (code.contains("lib/spider.php")) {
            for (String dependency : List.of("lib/spider.php", "lib/HtmlParser.php")) {
                URI target = uri.resolve(dependency);
                // drpy-node protects /php/* with the same pwd query as the entry script.
                if (!"file".equals(uri.getScheme()) && uri.getRawQuery() != null) {
                    target = URI.create(target.toASCIIString() + "?" + uri.getRawQuery());
                }
                files.put(dependency, read(target));
            }
        }
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException("PHP source load cancelled");
        // All downloads must succeed before replacing any cached source file.
        for (var item : files.entrySet()) atomicWrite(dir.resolve(item.getKey()), item.getValue());
        try (InputStream bridge = PhpSource.class.getResourceAsStream("/php/bridge.php")) {
            if (bridge == null) throw new IOException("PHP bridge missing from companion");
            atomicWrite(dir.resolve(".xiugou-bridge.php"), bridge.readAllBytes());
        }
        return dir.resolve(name);
    }

    private static byte[] read(URI uri) throws IOException {
        URLConnection connection = null;
        try {
            InputStream stream;
            if ("file".equals(uri.getScheme())) stream = Files.newInputStream(Path.of(uri));
            else {
                connection = URI.create(uri.toASCIIString()).toURL().openConnection();
                connection.setConnectTimeout(15_000);
                connection.setReadTimeout(20_000);
                connection.setRequestProperty("User-Agent", "Mozilla/5.0 XiugouTV");
                stream = connection.getInputStream();
            }
            try (InputStream input = stream) {
                byte[] data = input.readNBytes(MAX_SOURCE + 1);
                if (data.length > MAX_SOURCE) throw new IOException("PHP 源文件超过 8 MiB");
                String prefix = new String(data, 0, Math.min(data.length, 256), StandardCharsets.UTF_8)
                        .replace("\uFEFF", "").stripLeading();
                if (!prefix.startsWith("<?php")) throw new IOException("源地址没有返回 PHP 代码，请使用 type:4 接口或 PHP 脚本原始地址");
                return data;
            }
        } catch (IOException failure) {
            // Do not propagate URLs, signed query parameters or local user paths.
            if (failure.getMessage() != null && (failure.getMessage().startsWith("PHP 源文件")
                    || failure.getMessage().startsWith("源地址没有"))) throw failure;
            throw new IOException("PHP 源或 lib/spider.php、lib/HtmlParser.php 依赖读取失败");
        } finally {
            if (connection instanceof HttpURLConnection http) http.disconnect();
        }
    }

    private static void atomicWrite(Path target, byte[] bytes) throws IOException {
        Files.createDirectories(target.getParent());
        Path pending = Files.createTempFile(target.getParent(), ".php-", ".pending");
        try {
            Files.write(pending, bytes);
            try { Files.move(pending, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); }
            catch (AtomicMoveNotSupportedException ignored) { Files.move(pending, target, StandardCopyOption.REPLACE_EXISTING); }
        } finally { Files.deleteIfExists(pending); }
    }

    private static String hash(String value) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
    }
}
