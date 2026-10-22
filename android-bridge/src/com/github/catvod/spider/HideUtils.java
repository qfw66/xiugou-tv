package com.github.catvod.spider;

import com.fongmi.companion.GuardHost;

/**
 * 加固壳（ftyguard）的宿主工具类。
 *
 * <p>ftyguard 载荷的中枢类（当前代是 {@code merge.g8}）在字节码里**直接引用**本类的四个
 * 静态方法：
 * <pre>
 *   encrypt(String) -&gt; String
 *   decrypt(String) -&gt; String
 *   tingMd5(String) -&gt; String
 *   calcResult(int[]) -&gt; int[]
 * </pre>
 * 手机端由壳自带的 dex/so 提供实现；桌面端没有壳运行库，过去只能靠壳的兜底分支
 * ——{@code InitOrigin.i.getDeclaredMethod(<混淆名>, String.class)} 反射问宿主
 * （见 {@link GuardHost}）。那个混淆名是**每代载荷随机生成**的，上游一换载荷就
 * 静默返回空串，表现为「首页有分类、分类里 0 部」。
 *
 * <p>本类补齐后，再把壳的开关 {@code merge.uA.yq} 置为 true，载荷就会走本类这条
 * **稳定接口**，不再触碰任何混淆方法名。以后上游换代只要这四个签名不变即可自动适配。
 *
 * <p>实现统一委托给 {@link GuardHost}，保证离线解密映射表（EXT_MAP）只有一份。
 */
public final class HideUtils {

    private HideUtils() {
    }

    public static String encrypt(String s) {
        return GuardHost.encrypt(s);
    }

    public static String decrypt(String s) {
        return GuardHost.decrypt(s);
    }

    public static String tingMd5(String s) {
        return GuardHost.native_ting_md5(s);
    }

    public static int[] calcResult(int[] arr) {
        return GuardHost.calcResult(arr);
    }
}
