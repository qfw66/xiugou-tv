package com.fongmi.companion.hardshell;

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
import com.github.unidbg.linux.android.dvm.VaList;
import com.github.unidbg.linux.android.dvm.VarArg;
import com.github.unidbg.linux.android.dvm.array.ByteArray;

import java.io.File;
import java.nio.file.Files;
import java.util.Arrays;

/**
 * native 加固壳的一次性解包器：在 unidbg 上加载容器里的 ARM so，调用它注册的 native 方法，
 * 让壳自己把加密载荷解成普通 jar。
 *
 * <p><b>为什么必须模拟</b>：解密算法在 Android ARM so 里（无标准加密符号，明文串全加密），
 * Windows x64 无法直接加载 ARM 库，只能做指令级模拟。
 *
 * <p><b>为什么在子进程</b>：unidbg（约 27 MB + 原生库）按约定只进编译期 classpath，
 * 不进 companion 主 jar，所以本类由 {@link NativeProvisioner} 用
 * {@code -cp "<主 jar>;<dist>/lib-unidbg/*"} 拉起。
 *
 * <p><b>零源特化</b>：所有与具体壳相关的名字（so、载荷条目、包名、native 类与签名、
 * guest 路径）都来自 {@link ShellProfile}，本类不含任何 if-源的代码。
 *
 * <h3>壳的四道通用坎</h3>
 * 都会让朴素模拟静默返回 null：
 * <ol>
 *   <li>unidbg 的 JNI 派发走**非 V 变体**（{@code callObjectMethod}，参数 {@code VarArg}），
 *       只覆盖 {@code ...MethodV}（{@code VaList}）不生效；两套都要覆盖；</li>
 *   <li>非 V 变体的参数表是 <b>0 基、不含 this</b>；</li>
 *   <li>壳常做**反向环境自检**（要求某个宿主类加载失败才继续），
 *       {@code loadClass} 必须回 null；</li>
 *   <li>文件路径必须是 guest 侧 POSIX 路径（{@code setRootDir} 映射），
 *       喂 Windows 路径会静默不落盘。</li>
 * </ol>
 *
 * <p>退出码：0 成功；2 参数错误；3 容器缺条目；4 模拟失败；5 产物不合法。
 */
public final class NativeShellUnwrapper {

    private final ShellProfile profile;
    private final String guestCache;
    private final String guestFiles;

    private byte[] plain;
    private int cursor;

    public NativeShellUnwrapper(ShellProfile profile) {
        this.profile = profile;
        String base = profile.guestBase;
        if (base.endsWith("/")) base = base.substring(0, base.length() - 1);
        this.guestCache = base + "/cache";
        this.guestFiles = base + "/files";
    }

    /** 解包并把结果写到 {@code outJar}；返回退出码。 */
    public int run(File container, File outJar) throws Exception {
        File work = Files.createTempDirectory("hardshell-unwrap-").toFile();
        try {
            File so = new File(work, profile.soNames[0]);
            boolean extracted = false;
            for (String name : profile.soNames) {
                File candidate = new File(work, name);
                if (JarIndex.extract(container, name, candidate)) {
                    so = candidate;
                    extracted = true;
                    break;
                }
            }
            if (!extracted) {
                System.err.println("[Hardshell/unwrap] 容器里没有 " + Arrays.toString(profile.soNames));
                return 3;
            }

            File payloadFile = new File(work, profile.payloadEntry);
            if (!JarIndex.extract(container, profile.payloadEntry, payloadFile)) {
                System.err.println("[Hardshell/unwrap] 容器里没有 " + profile.payloadEntry);
                return 3;
            }
            plain = Files.readAllBytes(payloadFile.toPath());
            cursor = 0;

            File root = new File(work, "guest");
            // guest 路径必须落在 rootDir 下的同名相对位置，否则壳写出的文件在宿主机上找不到。
            File cacheDir = new File(root, guestCache.substring(1));
            File filesDir = new File(root, guestFiles.substring(1));
            cacheDir.mkdirs();
            filesDir.mkdirs();

            AndroidEmulator emulator = AndroidEmulatorBuilder.for64Bit()
                    .setProcessName(profile.packageName)
                    .setRootDir(root)
                    .build();
            emulator.getMemory().setLibraryResolver(new AndroidResolver(23));

            VM vm = emulator.createDalvikVM();
            vm.setJni(new Shim(cacheDir, filesDir));

            DalvikModule dm = vm.loadLibrary(so, true);
            dm.callJNI_OnLoad(emulator);

            DvmClass nativeClass = vm.resolveClass(profile.nativeClass);
            DvmObject<?> ctx = new DvmObject<Object>(vm.resolveClass("android/app/Application"), "ctx") {
            };
            DvmObject<?> stream = new DvmObject<Object>(vm.resolveClass("java/io/InputStream"), "stream") {
            };

            nativeClass.callStaticJniMethodObject(emulator, profile.unwrapSignature, ctx, stream);
            emulator.close();

            if (cursor != plain.length) {
                System.err.println("[Hardshell/unwrap] 载荷未读完: " + cursor + "/" + plain.length);
                return 4;
            }

            File produced = new File(cacheDir, profile.decryptedName);
            if (!produced.isFile() || produced.length() == 0) {
                System.err.println("[Hardshell/unwrap] 壳没有产出解密文件: " + produced);
                return 4;
            }

            File parent = outJar.getParentFile();
            if (parent != null) parent.mkdirs();
            Files.move(produced.toPath(), outJar.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);

            if (!profile.isPayload(outJar)) {
                System.err.println("[Hardshell/unwrap] 产物不是预期载荷（缺 "
                        + Arrays.toString(profile.payloadMarkers) + "）: " + outJar.length() + " B");
                return 5;
            }
            System.out.println("[Hardshell/unwrap] OK " + outJar.getName() + " " + outJar.length() + " B");
            return 0;
        } finally {
            deleteQuietly(work);
        }
    }

    // ------------------------------------------------------------------ JNI 垫片

    private final class Shim extends AbstractJni {

        private final File cacheDir;
        private final File filesDir;

        Shim(File cacheDir, File filesDir) {
            this.cacheDir = cacheDir;
            this.filesDir = filesDir;
        }

        @Override
        public DvmObject<?> callObjectMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            return handleObject(vm, o, s, a);
        }

        @Override
        public DvmObject<?> callObjectMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
            return handleObject(vm, o, s, a);
        }

        @Override
        public int callIntMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            return handleInt(s, a);
        }

        @Override
        public int callIntMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
            return handleInt(s, a);
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
        public long callLongMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            return 0L;
        }

        @Override
        public long callLongMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
            return 0L;
        }

        @Override
        public void callVoidMethodV(BaseVM vm, DvmObject<?> o, String s, VaList a) {
            // no-op：壳只关心解密结果，写文件的可见性由 rootDir 映射保证
        }

        @Override
        public void callVoidMethod(BaseVM vm, DvmObject<?> o, String s, VarArg a) {
        }

        @Override
        public DvmObject<?> newObjectV(BaseVM vm, DvmClass c, String s, VaList a) {
            return new DvmObject<Object>(c, s) {
            };
        }

        @Override
        public DvmObject<?> newObject(BaseVM vm, DvmClass c, String s, VarArg a) {
            return new DvmObject<Object>(c, s) {
            };
        }

        @Override
        public DvmObject<?> callStaticObjectMethodV(BaseVM vm, DvmClass c, String s, VaList a) {
            return s.endsWith(")Ljava/lang/String;") ? new StringObject(vm, "") : null;
        }

        @Override
        public DvmObject<?> callStaticObjectMethod(BaseVM vm, DvmClass c, String s, VarArg a) {
            return s.endsWith(")Ljava/lang/String;") ? new StringObject(vm, "") : null;
        }

        @Override
        public int getStaticIntField(BaseVM vm, DvmClass c, String s) {
            return 23;
        }

        @Override
        public int getIntField(BaseVM vm, DvmObject<?> o, String s) {
            return 0;
        }

        @Override
        public DvmObject<?> getObjectField(BaseVM vm, DvmObject<?> o, String s) {
            return null;
        }

        private DvmObject<?> handleObject(VM vm, DvmObject<?> obj, String sig, VarArg va) {
            if (sig.endsWith("->getCacheDir()Ljava/io/File;")) return fileObject(vm, cacheDir);
            if (sig.endsWith("->getFilesDir()Ljava/io/File;")) return fileObject(vm, filesDir);
            if (sig.endsWith("->getExternalFilesDir(Ljava/lang/String;)Ljava/io/File;")) {
                return fileObject(vm, filesDir);
            }
            switch (sig) {
                case "android/app/Application->getPackageName()Ljava/lang/String;":
                case "android/content/Context->getPackageName()Ljava/lang/String;":
                case "android/content/ContextWrapper->getPackageName()Ljava/lang/String;":
                    return new StringObject(vm, profile.packageName);
                case "java/io/File->getAbsolutePath()Ljava/lang/String;":
                case "java/io/File->getPath()Ljava/lang/String;":
                    return new StringObject(vm, guestPath(obj));
                case "java/io/File->getParent()Ljava/lang/String;": {
                    String p = guestPath(obj);
                    int i = p.lastIndexOf('/');
                    return new StringObject(vm, i > 0 ? p.substring(0, i) : "/");
                }
                case "java/io/File->getName()Ljava/lang/String;": {
                    String p = guestPath(obj);
                    return new StringObject(vm, p.substring(p.lastIndexOf('/') + 1));
                }
                case "java/lang/ClassLoader->loadClass(Ljava/lang/String;)Ljava/lang/Class;":
                    // 反向自检：壳要求宿主类**不可**加载才会继续解密。
                    return null;
                default: {
                    int i = sig.indexOf(')');
                    String ret = i >= 0 ? sig.substring(i + 1) : "";
                    if ("Ljava/lang/String;".equals(ret)) return new StringObject(vm, "");
                    if (ret.startsWith("L") && ret.endsWith(";")) {
                        return new DvmObject<Object>(
                                vm.resolveClass(ret.substring(1, ret.length() - 1)), sig) {
                        };
                    }
                    return null;
                }
            }
        }

        private int handleInt(String sig, VarArg va) {
            if ("java/io/InputStream->read([B)I".equals(sig)) {
                ByteArray arr = va.getObjectArg(0);
                int want = arr.length();
                int n = Math.min(want, plain.length - cursor);
                if (n <= 0) return -1;
                byte[] dst = new byte[want];
                System.arraycopy(plain, cursor, dst, 0, n);
                arr.setValue(dst);
                cursor += n;
                return n;
            }
            if ("java/io/InputStream->read([BII)I".equals(sig)) {
                ByteArray arr = va.getObjectArg(0);
                int off = va.getIntArg(1);
                int len = va.getIntArg(2);
                int n = Math.min(len, plain.length - cursor);
                if (n <= 0) return -1;
                arr.setData(off, Arrays.copyOfRange(plain, cursor, cursor + n));
                cursor += n;
                return n;
            }
            if ("java/io/InputStream->available()I".equals(sig)) {
                return plain.length - cursor;
            }
            return 0;
        }

        private DvmObject<?> fileObject(VM vm, File f) {
            return new DvmObject<File>(vm.resolveClass("java/io/File"), f) {
            };
        }

        /** guest 侧路径：直接回传固定映射值，不在宿主路径上做字符串推理。 */
        private String guestPath(DvmObject<?> obj) {
            File f = (File) obj.getValue();
            if (f.equals(cacheDir)) return guestCache;
            if (f.equals(filesDir)) return guestFiles;
            // 壳从 cacheDir 派生子路径时，按前缀映射回 guest 视图。
            String abs = f.getAbsolutePath();
            String cacheHost = cacheDir.getAbsolutePath();
            String filesHost = filesDir.getAbsolutePath();
            if (abs.startsWith(cacheHost)) {
                return guestCache + abs.substring(cacheHost.length()).replace('\\', '/');
            }
            if (abs.startsWith(filesHost)) {
                return guestFiles + abs.substring(filesHost.length()).replace('\\', '/');
            }
            return abs.replace('\\', '/');
        }
    }

    private static void deleteQuietly(File dir) {
        File[] kids = dir.listFiles();
        if (kids != null) {
            for (File kid : kids) deleteQuietly(kid);
        }
        //noinspection ResultOfMethodCallIgnored
        dir.delete();
    }
}
