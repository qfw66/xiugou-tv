package com.github.catvod.spider;

/**
 * 混淆 spider jar 引用的宿主辅助类（merge/* 内部使用）。
 * 手机端由打包进 APK 的实现提供；桌面端以空实现保证链接期通过。
 * 调用点：HideAPI.R(HideAPI) —— 参考 javap 字节码。
 */
public class HideAPI {

    public static void R(HideAPI api) {
        // no-op：桌面端无需该弹窗/提示行为
    }
}
