package com.fongmi.companion.hardshell;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 修补器链：按 profile 声明的 {@code repair.ids} 依次执行，也可运行期追加。
 *
 * <p>未声明 {@code repair.ids} 的载荷一次都不跑修补器，因此既有站点的加载路径
 * 与引入本框架之前完全一致。
 */
public final class RepairChain {

    private static final CopyOnWriteArrayList<PayloadRepair> REGISTERED = new CopyOnWriteArrayList<>();

    static {
        REGISTERED.add(new CtorInlineRepair());
    }

    private RepairChain() {
    }

    /** 注册一个修补器（同 id 覆盖旧的）。 */
    public static void register(PayloadRepair repair) {
        if (repair == null) return;
        REGISTERED.removeIf(r -> r.id().equals(repair.id()));
        REGISTERED.add(repair);
    }

    /** 已有修补器 id 列表（日志/诊断用）。 */
    public static List<String> ids() {
        List<String> out = new ArrayList<>();
        for (PayloadRepair r : REGISTERED) out.add(r.id());
        return out;
    }

    /**
     * 该 profile 修补链的版本戳（如 {@code -rctor-inline3}）；未声明修补器时为空串。
     * 用作转换产物文件名的一部分，修补器升级后旧产物自动失效。
     */
    public static String stamp(ShellProfile profile) {
        if (profile == null || profile.repairIds.length == 0) return "";
        StringBuilder sb = new StringBuilder("-r");
        for (String id : profile.repairIds) {
            int version = 0;
            for (PayloadRepair r : REGISTERED) {
                if (r.id().equalsIgnoreCase(id)) {
                    version = r.version();
                    break;
                }
            }
            sb.append(id.replaceAll("[^A-Za-z0-9-]", "")).append(version);
        }
        return sb.toString();
    }

    /**
     * 按 profile 声明的顺序执行修补器。
     *
     * @return 是否至少有一个修补器改写了产物
     */
    public static boolean run(File converted, ShellProfile profile) {
        if (profile == null || profile.repairIds.length == 0) return false;
        boolean changed = false;
        for (String id : profile.repairIds) {
            for (PayloadRepair r : REGISTERED) {
                if (!r.id().equalsIgnoreCase(id)) continue;
                try {
                    if (r.repair(converted)) changed = true;
                } catch (Throwable t) {
                    System.err.println("[Hardshell/repair] " + id + " 异常，跳过: " + t);
                }
                break;
            }
        }
        return changed;
    }
}
