package com.fongmi.companion.hardshell;

import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.Module;
import com.github.unidbg.arm.backend.Backend;
import com.github.unidbg.arm.backend.CodeHook;
import com.github.unidbg.arm.backend.UnHook;
import com.github.unidbg.linux.android.AndroidEmulatorBuilder;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.AbstractJni;
import com.github.unidbg.linux.android.dvm.BaseVM;
import com.github.unidbg.linux.android.dvm.DalvikModule;
import com.github.unidbg.linux.android.dvm.DvmClass;
import com.github.unidbg.linux.android.dvm.DvmObject;
import com.github.unidbg.linux.android.dvm.StringObject;
import com.github.unidbg.linux.android.dvm.VM;
import com.github.unidbg.linux.android.dvm.VaList;
import com.github.unidbg.linux.android.dvm.VarArg;
import com.github.unidbg.linux.android.dvm.array.ByteArray;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import com.fongmi.companion.fs.NativeCache;

import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 载荷 native 服务的子进程端：在 unidbg 里加载载荷自带的 native 库，按签名代调其注册的方法。
 *
 * <p>由 {@link PayloadCryptoService} 以
 * {@code java -cp "<main jar>;<dist>/lib-unidbg/*" com.fongmi.companion.hardshell.PayloadCryptoMain
 * <payload.jar> <profileId> [profilesDir]} 拉起；unidbg 类只允许出现在这个类里（父 JVM 无 unidbg）。
 *
 * <p>协议（stdin/stdout 逐行，全部 ASCII）：
 * <pre>
 *   → CALL \t &lt;方法签名&gt; [\t 参数]...   参数：N=null，I&lt;十进制&gt;，S&lt;base64 UTF-8&gt;，B&lt;base64&gt;
 *   ← OK \t B&lt;base64&gt; | OK \t S&lt;base64&gt; | NIL | ERR \t &lt;base64 消息&gt;
 * </pre>
 * 启动成功（{@code JNI_OnLoad} 返回且无异常）后先输出一行 {@code READY}。
 *
 * <p>每行响应都以 {@link #FRAME} 开头：guest 里的 native 会直接往进程 fd 1 写日志（unidbg 把 guest
 * stdout 映射到宿主 fd 1，{@code System.setOut} 管不到），客户端只认帧标记之后的内容。
 */
public final class PayloadCryptoMain {

    /** 响应帧标记，见类注释。 */
    static final String FRAME = "PC";

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: PayloadCryptoMain <payload.jar> <profileId> [profilesDir]");
            System.exit(2);
            return;
        }
        if (args.length >= 3 && !JarIndex.isEmpty(args[2])) {
            System.setProperty("xiugou.hardshell.profiles", args[2]);
        }
        ShellProfile profile = ShellRegistry.byId(args[1]);
        if (profile == null || !profile.hasCrypto()) {
            System.err.println("[PayloadCrypto] 形态不存在或未声明 crypto.so: " + args[1]);
            System.exit(2);
            return;
        }
        // 协议独占真实 stdout；unidbg 与 native 回调的日志全部改道 stderr，防止串行。
        PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        System.setOut(System.err);

        Host host = new Host(profile, new File(args[0]));
        out.println(FRAME + "READY");
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = in.readLine()) != null) {
            if (line.isEmpty()) continue;
            if ("QUIT".equals(line)) break;
            out.println(FRAME + host.handle(line));
        }
        out.flush();
    }

    /** 一个已完成 {@code JNI_OnLoad} 的载荷库实例。 */
    static final class Host {

        private final AndroidEmulator emulator;
        private final VM vm;
        private final DvmClass target;

        Host(ShellProfile profile, File payloadJar) throws Exception {
            File so = extract(payloadJar, profile.cryptoSo);
            if (so == null) {
                throw new IOException("载荷里没有 " + String.join("|", profile.cryptoSo) + ": " + payloadJar);
            }
            emulator = AndroidEmulatorBuilder.for64Bit().setProcessName(profile.packageName).build();
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
            vm = emulator.createDalvikVM();
            vm.setJni(new LooseJni(profile.packageName));
            vm.setVerbose(Boolean.getBoolean("payloadcrypto.verbose"));
            DalvikModule dm = vm.loadLibrary(so, true);
            pinPerInstruction();
            applyEnv(profile.cryptoEnv);
            dm.callJNI_OnLoad(emulator);
            target = vm.resolveClass(profile.cryptoClass.replace('.', '/'));
            System.err.println("[PayloadCrypto] ready: " + profile.id + " " + so.getName());
        }

        String handle(String line) {
            try {
                String[] parts = line.split("\t", -1);
                if (!"CALL".equals(parts[0]) || parts.length < 2) return "ERR\t" + b64("bad request");
                List<Object> callArgs = new ArrayList<>();
                for (int i = 2; i < parts.length; i++) callArgs.add(decodeArg(parts[i]));
                DvmObject<?> result = target.callStaticJniMethodObject(emulator, parts[1], callArgs.toArray());
                Object value = result == null ? null : result.getValue();
                if (value instanceof byte[]) {
                    return "OK\tB" + java.util.Base64.getEncoder().encodeToString((byte[]) value);
                }
                if (value instanceof String) return "OK\tS" + b64((String) value);
                return "NIL";
            } catch (Throwable t) {
                return "ERR\t" + b64(String.valueOf(t));
            }
        }

        private Object decodeArg(String token) {
            if (token.isEmpty() || "N".equals(token)) return null;
            String body = token.substring(1);
            switch (token.charAt(0)) {
                case 'I':
                    return Integer.parseInt(body);
                case 'S':
                    return new StringObject(vm, new String(java.util.Base64.getDecoder().decode(body),
                            StandardCharsets.UTF_8));
                case 'B':
                    return new ByteArray(vm, java.util.Base64.getDecoder().decode(body));
                default:
                    throw new IllegalArgumentException("unknown arg token: " + token.charAt(0));
            }
        }

        /**
         * 在整个 guest 地址空间挂一个空代码钩子，迫使 unicorn 逐条执行。
         *
         * <p>awenc 会在运行期生成/改写可执行代码（落在库映像之外，所以只钩库范围无效）；unicorn
         * 无钩子时复用已翻译的代码块，看不到改写，实测 {@code awSign(时间戳, key)} 必崩
         * （{@code UC_ERR_FETCH_UNMAPPED}），且崩后整个模拟器不可再用。
         */
        private void pinPerInstruction() {
            emulator.getBackend().hook_add_new(new CodeHook() {
                @Override
                public void hook(Backend backend, long address, int size, Object user) {
                }

                @Override
                public void onAttach(UnHook unHook) {
                }

                @Override
                public void detach() {
                }
            }, 0, 0xffffffffL, null);
        }

        /** 必须在 {@code JNI_OnLoad} 之前写进 guest 的 libc 环境，见 {@link ShellProfile#cryptoEnv}。 */
        private void applyEnv(String[] pairs) {
            if (pairs.length == 0) return;
            Module libc = emulator.getMemory().findModule("libc.so");
            if (libc == null) throw new IllegalStateException("guest 未加载 libc.so，无法 setenv");
            for (String pair : pairs) {
                int eq = pair.indexOf('=');
                if (eq <= 0) continue;
                libc.callFunction(emulator, "setenv", pair.substring(0, eq), pair.substring(eq + 1), 1);
            }
        }
    }

    /**
     * 宽松 JNI 垫片：载荷库在 {@code JNI_OnLoad} 里只做宿主探测（取 Application、应用名、
     * {@code assets.list}、弹提示），结果不影响 {@code RegisterNatives}，所以对象按返回类型造、
     * 原始类型返回零值即可；唯一需要真值的是包名。
     */
    static final class LooseJni extends AbstractJni {

        private final String packageName;

        LooseJni(String packageName) {
            this.packageName = packageName;
        }

        private DvmObject<?> make(BaseVM vm, String sig) {
            if (sig.endsWith("getPackageName()Ljava/lang/String;")) return new StringObject(vm, packageName);
            String ret = sig.substring(sig.indexOf(')') + 1);
            if ("Ljava/lang/String;".equals(ret)) return new StringObject(vm, "");
            if (ret.startsWith("L") && ret.endsWith(";")) {
                return vm.resolveClass(ret.substring(1, ret.length() - 1)).newObject(sig);
            }
            return null;
        }

        private static String fieldSig(String s) {
            return "()" + s.substring(s.indexOf(':') + 1);
        }

        @Override
        public DvmObject<?> callStaticObjectMethodV(BaseVM vm, DvmClass c, String s, VaList a) {
            return make(vm, s);
        }

        @Override
        public DvmObject<?> callStaticObjectMethod(BaseVM vm, DvmClass c, String s, VarArg a) {
            return make(vm, s);
        }

        @Override
        public DvmObject<?> callObjectMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            return make(vm, s);
        }

        @Override
        public DvmObject<?> callObjectMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
            return make(vm, s);
        }

        @Override
        public DvmObject<?> getStaticObjectField(BaseVM vm, DvmClass c, String s) {
            return make(vm, fieldSig(s));
        }

        @Override
        public DvmObject<?> getObjectField(BaseVM vm, DvmObject<?> o, String s) {
            return make(vm, fieldSig(s));
        }

        @Override
        public DvmObject<?> newObjectV(BaseVM vm, DvmClass c, String s, VaList a) {
            return c.newObject(s);
        }

        @Override
        public DvmObject<?> newObject(BaseVM vm, DvmClass c, String s, VarArg a) {
            return c.newObject(s);
        }

        @Override
        public int getStaticIntField(BaseVM vm, DvmClass c, String s) {
            return 23;
        }

        @Override
        public int callIntMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            return 0;
        }

        @Override
        public int callIntMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
            return 0;
        }

        @Override
        public int callStaticIntMethod(BaseVM vm, DvmClass c, String s, VarArg a) {
            return 0;
        }

        @Override
        public boolean callBooleanMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            return false;
        }

        @Override
        public boolean callBooleanMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
            return false;
        }

        @Override
        public boolean callStaticBooleanMethod(BaseVM vm, DvmClass c, String s, VarArg a) {
            return false;
        }

        @Override
        public void callVoidMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
        }

        @Override
        public void callVoidMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
        }

        @Override
        public void callStaticVoidMethodV(BaseVM vm, DvmClass c, String s, VaList a) {
        }

        @Override
        public void callStaticVoidMethod(BaseVM vm, DvmClass c, String s, VarArg a) {
        }
    }

    /** 取第一个存在的库条目，按内容哈希落地复用（见 {@link NativeCache}）。 */
    private static File extract(File jar, String[] entries) throws IOException {
        try (ZipFile zip = new ZipFile(jar)) {
            for (String name : entries) {
                ZipEntry entry = zip.getEntry(name);
                if (entry == null || entry.getSize() == 0) continue;
                return NativeCache.materialize(new File(name).getName(), zip.getInputStream(entry));
            }
        }
        return null;
    }

    private static String b64(String value) {
        return java.util.Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private PayloadCryptoMain() {
    }
}
