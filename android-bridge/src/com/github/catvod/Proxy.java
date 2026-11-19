package com.github.catvod;

/**
 * FongMi 系宿主壳里的 {@code com.github.catvod.Proxy}：{@code getHostPort()} 是壳内本地消息服务的
 * {@code host:port}，载荷的 {@code Util.notify} 往它 POST 提示文字。
 *
 * <p>桌面版没有这个消息服务，返回空串：载荷自己的实现在地址为空时直接跳过发送
 * （提示内容仍会经 SpiderDebug 进调试日志）。不要返回 companion 的 RPC 端口——那不是同一个协议。
 */
public final class Proxy {
    private Proxy() {
    }

    public static String getHostPort() {
        return "";
    }
}
