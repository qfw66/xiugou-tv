package com.fongmi.companion.hardshell;

import java.io.File;

/**
 * 加固壳处理管线的唯一对外入口。调用方（{@code DexSpiderLoader}）只认这三个方法，
 * <b>不需要知道有哪些源、也不随新增源而改动</b>。
 *
 * <pre>
 *   ① cached(cacheDir, key)          纯查缓存（壳 jar 还没下载时用）
 *   ② resolve(cacheDir, shellJar, key)  识别 → 取容器 → 解包 → 验收 → 落盘
 *   ③ repair(converted, sourceJar)   按源声明的修补器链修 dex2jar 产物
 * </pre>
 *
 * <h3>新增一个加固源的完整步骤</h3>
 * 在 {@code <jars cache>/hardshell/} 放一个 properties（或改 {@link ShellRegistry#builtin()}）：
 * <pre>
 *   id=newname
 *   shell.markers=assets/xxx.bin
 *   payload.markers=assets/enc-v8.so
 *   so.names=xxx-v8.so;xxx-v7.so
 *   payload.entry=payload.amns
 *   decrypted.name=out.db
 *   repair.ids=ctor-inline
 * </pre>
 * 无 Java 代码改动。索引地址可省略（自动从壳 dex 字面量 + 资产名还原）。
 */
public final class HardshellPipeline {

    private HardshellPipeline() {
    }

    /**
     * 纯查缓存：该缓存键下是否已存在**任一**壳的解包产物。
     *
     * @param cacheDir jars 缓存目录
     * @param key      缓存键（既有约定是原始配置地址的 md5）
     */
    public static File cached(File cacheDir, String key) {
        if (cacheDir == null) return null;
        ShellRegistry.ensureLoaded(cacheDir);
        for (ShellProfile profile : ShellRegistry.all()) {
            File hit = new NativeProvisioner(profile).cached(cacheDir, key);
            if (hit != null) {
                System.out.println("[Hardshell] 命中本地载荷: " + hit.getName());
                return hit;
            }
        }
        return null;
    }

    /**
     * 识别 + 解包。{@code shellJar} 不属于任何已知壳时返回 {@code null}，
     * 调用方原有兜底路径照常执行。
     *
     * @param cacheDir jars 缓存目录
     * @param shellJar 已下载的 jar（可能是壳，也可能不是）
     * @param key      缓存键（通常是原始配置地址的 md5）
     */
    public static File resolve(File cacheDir, File shellJar, String key) {
        if (cacheDir == null || shellJar == null || !shellJar.isFile()) return null;
        ShellRegistry.ensureLoaded(cacheDir);
        ShellProfile profile = ShellRegistry.matchShell(shellJar);
        if (profile == null) return null;
        return new NativeProvisioner(profile).ensure(cacheDir, shellJar, key);
    }

    /**
     * 按源声明的修补器链修补 dex2jar 产物。
     *
     * <p>识别依据是产物自身特征（{@link ShellRegistry#matchPayload}），
     * 因此调用点无需知道自己正在处理哪个源。
     *
     * @param converted dex2jar 产物（就地修补）
     * @param sourceJar 修补前的原始载荷 jar（用于判定形态）
     * @return 是否改写了产物
     */
    public static boolean repair(File converted, File sourceJar) {
        if (converted == null || !converted.isFile()) return false;
        ShellProfile profile = ShellRegistry.matchPayload(sourceJar);
        if (profile == null || profile.repairIds.length == 0) return false;
        return RepairChain.run(converted, profile);
    }

    /** 转换产物缓存名里的修补链版本戳；非加固载荷为空串（不影响既有缓存名）。 */
    public static String repairStamp(File sourceJar) {
        return RepairChain.stamp(ShellRegistry.matchPayload(sourceJar));
    }

    /** 加固载荷自己的初始化入口类（{@code payload.init}）；非加固载荷或未声明时为 null。 */
    public static String payloadInit(File sourceJar) {
        ShellProfile profile = ShellRegistry.matchPayload(sourceJar);
        return profile == null || JarIndex.isEmpty(profile.payloadInit) ? null : profile.payloadInit;
    }

    /** 该 jar 是否任一已知壳的容器（诊断用）。 */
    public static boolean isShell(File jar) {
        return ShellRegistry.matchShell(jar) != null;
    }

    /** 该 jar 是否任一已知壳的解密载荷（诊断用）。 */
    public static boolean isPayload(File jar) {
        return ShellRegistry.matchPayload(jar) != null;
    }
}
