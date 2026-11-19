package com.github.catvod;

import android.app.Application;

/**
 * FongMi 系宿主壳里的 {@code com.github.catvod.Init}。载荷自带的 utils（Path / Prefers / Util）
 * 通过 {@code Init.context()} 取全局 Application；桌面版返回 companion 的 Application 单例。
 */
public final class Init {
    private Init() {
    }

    public static Application context() {
        return Application.get();
    }
}
