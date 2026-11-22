package com.fongmi.companion.hardshell;

import com.fongmi.companion.fs.NativeCache;
import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.AndroidEmulatorBuilder;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.AbstractJni;
import com.github.unidbg.linux.android.dvm.BaseVM;
import com.github.unidbg.linux.android.dvm.DalvikModule;
import com.github.unidbg.linux.android.dvm.DvmClass;
import com.github.unidbg.linux.android.dvm.DvmObject;
import com.github.unidbg.linux.android.dvm.StringObject;
import com.github.unidbg.linux.android.dvm.VM;
import com.github.unidbg.linux.android.dvm.VarArg;
import com.github.unidbg.linux.android.dvm.array.ByteArray;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** 执行真实载荷注册的原生方法，unidbg 不进入主服务的类加载路径。 */
public final class FishNativeMain {
    private static final String PACKAGE = "com.fongmi.android.tv";

    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("FishNativeMain <payload> <sha256> <rootfs>");
        PrintStream protocol = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        System.setOut(System.err);
        File payload = new File(args[0]);
        var library = FishNativeService.verifiedLibrary(payload, args[1]);
        File so = NativeCache.materialize("FishGuard-v8.so", new ByteArrayInputStream(library.bytes()));
        if (!library.digest().equals(FishNativeService.sha256(so))) {
            throw new IllegalStateException("Fish 原生缓存内容校验失败，请清除损坏的缓存后重新加载配置");
        }
        try (AndroidEmulator emulator = AndroidEmulatorBuilder.for64Bit().setProcessName(PACKAGE).setRootDir(new File(args[2])).build()) {
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));
            VM vm = emulator.createDalvikVM(payload);
            vm.setJni(new FishJni());
            vm.setVerbose(false);
            DalvikModule module = vm.loadLibrary(so, true);
            module.callJNI_OnLoad(emulator);
            DvmClass target = vm.resolveClass("com/github/catvod/utils/FishNative");
            target.callStaticJniMethod(emulator, "register()V");
            protocol.println(FishNativeService.FRAME + "READY");
            BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
            String line;
            while ((line = input.readLine()) != null) {
                try {
                    if (line.length() > 2 * 1024 * 1024) throw new IllegalArgumentException();
                    String[] parts = line.split("\t", -1);
                    String signature = parts[0];
                    Object[] nativeArgs = new Object[parts.length - 1];
                    for (int i = 1; i < parts.length; i++) {
                        String value = parts[i].substring(1);
                        switch (parts[i].charAt(0)) {
                            case 'N': nativeArgs[i - 1] = null; break;
                            case 'C': nativeArgs[i - 1] = vm.resolveClass("android/content/Context").newObject(null); break;
                            case 'S': nativeArgs[i - 1] = new StringObject(vm, new String(Base64.getDecoder().decode(value), StandardCharsets.UTF_8)); break;
                            case 'B': nativeArgs[i - 1] = new ByteArray(vm, Base64.getDecoder().decode(value)); break;
                            case 'I': nativeArgs[i - 1] = Integer.parseInt(value); break;
                            case 'J': nativeArgs[i - 1] = Long.parseLong(value); break;
                            case 'Z': nativeArgs[i - 1] = Boolean.parseBoolean(value) ? 1 : 0; break;
                            default: throw new IllegalArgumentException();
                        }
                    }
                    String result;
                    switch (signature.substring(signature.indexOf(')') + 1)) {
                        case "V": target.callStaticJniMethod(emulator, signature, nativeArgs); result = "V"; break;
                        case "I": result = "I" + target.callStaticJniMethodInt(emulator, signature, nativeArgs); break;
                        case "J": result = "J" + target.callStaticJniMethodLong(emulator, signature, nativeArgs); break;
                        case "Z": result = "Z" + target.callStaticJniMethodBoolean(emulator, signature, nativeArgs); break;
                        default:
                            DvmObject<?> object = target.callStaticJniMethodObject(emulator, signature, nativeArgs);
                            Object value = object == null ? null : object.getValue();
                            if (value == null) result = "N";
                            else if (value instanceof byte[]) result = "B" + b64((byte[]) value);
                            else if (value instanceof String) result = "S" + b64(((String) value).getBytes(StandardCharsets.UTF_8));
                            else if (value instanceof DvmObject[]) {
                                java.util.List<String> items = new java.util.ArrayList<>();
                                for (DvmObject<?> item : (DvmObject<?>[]) value) items.add(item == null ? "~" :
                                        b64(((String) item.getValue()).getBytes(StandardCharsets.UTF_8)));
                                result = "A" + String.join(",", items);
                            } else throw new IllegalStateException();
                    }
                    protocol.println(FishNativeService.FRAME + "OK\t" + result);
                } catch (Exception invalid) {
                    System.err.println("[FishNative] 原生调用失败: " + invalid.getClass().getName());
                    protocol.println(FishNativeService.FRAME + "ERR");
                }
            }
        }
    }

    private static String b64(byte[] bytes) { return Base64.getEncoder().encodeToString(bytes); }

    private static final class FishJni extends AbstractJni {
        @Override
        public DvmObject<?> callStaticObjectMethod(BaseVM vm, DvmClass owner, String signature, VarArg args) {
            if ("com/github/catvod/spider/Init->context()Landroid/app/Application;".equals(signature)) {
                return vm.resolveClass("android/app/Application", vm.resolveClass("android/content/Context")).newObject(null);
            }
            return super.callStaticObjectMethod(vm, owner, signature, args);
        }

        @Override
        public DvmObject<?> callObjectMethod(BaseVM vm, DvmObject<?> receiver, String signature, VarArg args) {
            if (signature.endsWith("->getFilesDir()Ljava/io/File;")) {
                return vm.resolveClass("java/io/File").newObject("/data/user/0/" + PACKAGE + "/files");
            }
            if ("java/io/File->getAbsolutePath()Ljava/lang/String;".equals(signature)) {
                return new StringObject(vm, String.valueOf(receiver.getValue()));
            }
            if (signature.endsWith("->getPackageName()Ljava/lang/String;")) return new StringObject(vm, PACKAGE);
            return super.callObjectMethod(vm, receiver, signature, args);
        }
    }
}
