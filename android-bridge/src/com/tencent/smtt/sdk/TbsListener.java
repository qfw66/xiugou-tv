package com.tencent.smtt.sdk;

/** 桌面端载荷初始化使用的 TBS 下载状态回调契约。 */
public interface TbsListener {
    void onDownloadFinish(int errorCode);

    void onDownloadProgress(int progress);

    void onInstallFinish(int errorCode);
}
