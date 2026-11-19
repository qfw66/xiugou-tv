package com.tencent.smtt.export.external.interfaces;

/** 载荷通过 invokeinterface 调用此接口，不创建任何 TLS 连接。 */
public interface SslErrorHandler {
    void proceed();
    void cancel();
}
