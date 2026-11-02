package com.fongmi.companion.hardshell;

import java.io.File;

/**
 * dex2jar 产物的一种坍塌修补器。加固载荷经 {@code PreciseDex2jar} 转换后，
 * 会因 ART 的编译期优化丢失信息而塌成非法字节码；每种坍塌对应一个修补器。
 *
 * <p><b>为什么是接口</b>：坍塌类型是"字节码事实"，与源无关。新源遇到新坍塌时，
 * 实现本接口并在 {@link RepairChain} 注册即可，调用方（{@link HardshellPipeline}）不变。
 *
 * <p><b>契约</b>：{@link #repair} 必须自己判断"真的需要修吗"——不需要时返回 false 且
 * <b>不得改写文件</b>，这样未受影响的站点行为与修补链不存在时完全一致。
 */
public interface PayloadRepair {

    /** 稳定标识，profile 的 {@code repair.ids} 用它挑选修补器。 */
    String id();

    /**
     * 修补逻辑版本：改了修补逻辑就递增。它进入转换产物的缓存文件名，
     * 旧版本修补出的产物因此自动作废、重新转换（否则会一直用旧缺陷产物）。
     */
    default int version() {
        return 1;
    }

    /**
     * 就地修补。
     *
     * @return true 表示产物已被改写；false 表示无需修补或修补失败（调用方保留原产物）
     */
    boolean repair(File converted);
}
