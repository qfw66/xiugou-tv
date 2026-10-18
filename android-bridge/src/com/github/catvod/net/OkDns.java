package com.github.catvod.net;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import okhttp3.Dns;

/**
 * 对齐手机端 com.github.catvod.net.OkDns 的简化版：
 * hosts 映射（精确 / 后缀 / *. 通配）优先，其余交给系统解析（Dns.SYSTEM）。
 *
 * 手机端在系统解析之上还叠加了 DoH 兜底（Doh + DnsOverHttps），桌面端保持
 * 同语义的最小实现；spider jar 通过 Spider.safeDns() 依赖本对象。
 */
public class OkDns implements Dns {

    private final ConcurrentHashMap<String, String> map = new ConcurrentHashMap<>();

    public void clear() {
        map.clear();
    }

    /** hosts 行格式: "example.com=1.2.3.4"（与手机端 addAllHosts 对齐）。 */
    public void addAll(List<String> hosts) {
        if (hosts == null) return;
        for (String host : hosts) {
            if (host == null) continue;
            String[] splits = host.split("=", 2);
            if (splits.length == 2) map.put(splits[0].trim(), splits[1].trim());
        }
    }

    private String get(String hostname) {
        String target = map.get(hostname);
        if (target != null) return target;
        for (Map.Entry<String, String> entry : map.entrySet()) {
            String key = entry.getKey();
            if (key.startsWith("*.") && hostname.endsWith(key.substring(1))) return entry.getValue();
            if (hostname.endsWith("." + key)) return entry.getValue();
        }
        return hostname;
    }

    @Override
    public List<InetAddress> lookup(String hostname) throws UnknownHostException {
        return Dns.SYSTEM.lookup(get(hostname));
    }
}
