package com.tencent.smtt.sdk;

import android.content.Context;

/**
 * 桌面端的最小 X5 SDK 兼容层。
 *
 * <p>桌面没有腾讯 X5 内核，因此只保留载荷初始化所需的静态契约，并明确报告内核不可用。
 */
public final class QbSdk {
    private QbSdk() {
    }

    public interface PreInitCallback {
        void onCoreInitFinished();

        void onViewInitFinished(boolean success);
    }

    public static void setDownloadWithoutWifi(boolean enabled) {
        // 桌面不下载或安装 Android X5 内核。
    }

    public static void setCoreMinVersion(int version) {
    }

    public static void setTbsListener(TbsListener listener) {
    }

    public static void initX5Environment(Context context, PreInitCallback callback) {
        if (callback == null) return;
        callback.onCoreInitFinished();
        callback.onViewInitFinished(false);
    }

    public static boolean isTbsCoreInited() {
        return false;
    }
}
