package com.fongmi.companion.source;

/**
 * 一次 spider 实例化请求：配置里一个站点的执行相关字段。
 *
 * @param siteKey  站点 key
 * @param api      配置原样 api（可能带 {@code csp_} 前缀、可能是 .py 地址）
 * @param cleanApi 去掉 {@code csp_/csp} 前缀后的类名部分
 * @param ext      已应用默认值后的 ext（可为 null）
 * @param jar      站点或全局 spider jar 地址（可为 null）
 */
public record SpiderRequest(String siteKey, String api, String cleanApi, String ext, String jar) {

    /** 是否声明了 jar。 */
    public boolean hasJar() {
        return jar != null && !jar.trim().isEmpty();
    }
}
