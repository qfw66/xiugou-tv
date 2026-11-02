package com.fongmi.companion.hardshell;

import java.io.File;

/**
 * 解包子进程入口。由 {@link NativeProvisioner} 以
 * {@code java -cp "<main jar>;<dist>/lib-unidbg/*" com.fongmi.companion.hardshell.UnwrapMain ...} 拉起。
 *
 * <p>参数：{@code <container.jar> <out.jar> <profileId> [profilesDir]}
 *
 * <p>单独成类是为了让 unidbg 类只在子进程里被加载——父 JVM 的 classpath 上没有 unidbg，
 * 任何对 {@link NativeShellUnwrapper} 的静态引用都会在父进程触发 NoClassDefFoundError。
 */
public final class UnwrapMain {

    public static void main(String[] args) {
        if (args.length < 3) {
            System.err.println("usage: UnwrapMain <container.jar> <out.jar> <profileId> [profilesDir]");
            System.exit(2);
            return;
        }
        try {
            if (args.length >= 4 && !JarIndex.isEmpty(args[3])) {
                System.setProperty("xiugou.hardshell.profiles", args[3]);
            }
            ShellProfile profile = ShellRegistry.byId(args[2]);
            if (profile == null) {
                System.err.println("[Hardshell/unwrap] 未知形态 id: " + args[2]);
                System.exit(2);
                return;
            }
            int code = new NativeShellUnwrapper(profile).run(new File(args[0]), new File(args[1]));
            System.exit(code);
        } catch (Throwable t) {
            System.err.println("[Hardshell/unwrap] failed: " + t);
            t.printStackTrace();
            System.exit(4);
        }
    }

    private UnwrapMain() {
    }
}
