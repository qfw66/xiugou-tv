package com.fongmi.companion.guard;

import com.github.unidbg.AndroidEmulator;
import com.github.unidbg.linux.android.AndroidEmulatorBuilder;
import com.github.unidbg.linux.android.AndroidResolver;
import com.github.unidbg.linux.android.dvm.AbstractJni;
import com.github.unidbg.linux.android.dvm.BaseVM;
import com.github.unidbg.linux.android.dvm.DalvikModule;
import com.github.unidbg.linux.android.dvm.DvmClass;
import com.github.unidbg.linux.android.dvm.DvmMethod;
import com.github.unidbg.linux.android.dvm.DvmObject;
import com.github.unidbg.linux.android.dvm.StringObject;
import com.github.unidbg.linux.android.dvm.VM;
import com.github.unidbg.linux.android.dvm.VaList;
import com.github.unidbg.linux.android.dvm.VarArg;
import com.github.unidbg.linux.android.dvm.wrapper.DvmBoolean;
import com.github.unidbg.linux.android.dvm.wrapper.DvmInteger;
import com.github.unidbg.linux.android.dvm.wrapper.DvmLong;
import com.github.unidbg.memory.Memory;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;

/**
 * 加固壳（ftyguard/wexguard）载荷解密器 —— 作为独立进程运行。
 *
 * 壳的 `assets/ftyshinidie.guard` 只能由 `assets/ftyguard_v7|v8.so` 里的 native 例程还原，
 * 桌面 JVM 无法直接执行 ARM 原生库，因此用 unidbg 跑一段 Android 运行时：
 * 构造 DalvikVM（以壳 jar 为 apk）、加载 so、调用 `DexNative.getLoader(Context)`，
 * 再把壳写出的 `cache/sharedb/config.db.saved`（= 明文载荷 zip）复制到指定输出路径。
 *
 * 刻意做成**独立进程**：
 * 1. unidbg 需要 27 MB 依赖与 unicorn 原生库，不该污染 companion 的运行时 classpath；
 * 2. 模拟器崩溃/超时不会拖垮常驻服务；
 * 3. 首次解密后结果按壳 md5 落盘复用，后续不再启动。
 *
 * 用法：`GuardDecryptor <shellJar> <outPayloadJar>`（成功 exit 0，失败非 0）。
 */
public class GuardDecryptor {

    static byte[] guardData;
    static DvmObject<?> classLoaderProxy;
    static File workDir;
    static DvmClass inputStreamCls;
    static DvmClass byteArrayInputStreamCls;
    static DvmClass fileInputStreamCls;
    static DvmClass outputStreamCls;
    static DvmClass fileOutputStreamCls;
    static DvmClass fileCls;

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: GuardDecryptor <shellJar> <outPayloadJar>");
            System.exit(2);
            return;
        }
        File shellJar = new File(args[0]);
        File outJar = new File(args[1]);
        if (!shellJar.isFile() || shellJar.length() == 0) {
            System.err.println("[GuardDecryptor] shell jar not found: " + shellJar);
            System.exit(3);
            return;
        }

        // 壳 jar（无论后缀是不是 .jar，本质是 zip 容器）解出 assets/* 到临时工作目录
        File stamp = new File(System.getProperty("java.io.tmpdir"),
                "guarddec-" + Long.toHexString(System.nanoTime()));
        File stage = new File(stamp, "shell");
        File cache = new File(stamp, "cache");
        stage.mkdirs();
        workDir = cache;
        workDir.mkdirs();
        extract(shellJar, stage);

        File soFile = pick(stage,
                "assets/ftyguard_v8.so", "assets/ftyguard_v7.so",
                "assets/wexguard_v8.so", "assets/wexguard_v7.so");
        File guardFile = pick(stage,
                "assets/ftyshinidie.guard", "assets/wexshinidie.guard");
        if (soFile == null || guardFile == null) {
            System.err.println("[GuardDecryptor] not a guard shell "
                    + "(missing assets/{fty|wex}guard_v*.so or {fty|wex}shinidie.guard)");
            System.exit(4);
            return;
        }
        File apkFile = shellJar;
        guardData = Files.readAllBytes(guardFile.toPath());
        // 预清理上一轮残留（config.db / *.saved），保证本轮产物来源唯一
        File sharedbDir = new File(workDir, "sharedb");
        if (sharedbDir.isDirectory()) {
            File[] olds = sharedbDir.listFiles();
            if (olds != null) for (File f : olds) { if (f.delete()) System.out.println("== 预清理: 删除 " + f.getName() + " (" + f.length() + "B)"); }
        }

        AndroidEmulator emulator = AndroidEmulatorBuilder.for64Bit()
                .setProcessName("com.fongmi.android.tv")
                .build();
        Memory memory = emulator.getMemory();
        memory.setLibraryResolver(new AndroidResolver(23));

        VM vm = emulator.createDalvikVM(apkFile);
        classLoaderProxy = vm.resolveClass("java/lang/ClassLoader").newObject("ShellClassLoader");
        fileCls = vm.resolveClass("java/io/File");
        inputStreamCls = vm.resolveClass("java/io/InputStream");
        byteArrayInputStreamCls = vm.resolveClass("java/io/ByteArrayInputStream", inputStreamCls);
        fileInputStreamCls = vm.resolveClass("java/io/FileInputStream", inputStreamCls);
        outputStreamCls = vm.resolveClass("java/io/OutputStream");
        fileOutputStreamCls = vm.resolveClass("java/io/FileOutputStream", outputStreamCls);

        vm.setJni(new AbstractJni() {

            // ================= 对象方法 =================
            @Override
            public DvmObject<?> callObjectMethod(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VarArg a) {
                return handleObj(bvm, obj, m, objArg(a, 0), strArg(a, 1));
            }

            @Override
            public DvmObject<?> callObjectMethodV(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VaList a) {
                return handleObj(bvm, obj, m, objArg(a, 0), strArg(a, 1));
            }

            // ================= 静态方法 =================
            @Override
            public DvmObject<?> callStaticObjectMethod(BaseVM bvm, DvmClass c, DvmMethod m, VarArg a) {
                System.out.println("== [Java-static] " + m.getSignature());
                if (m.getSignature().contains("classLoader()")) return classLoaderProxy;
                return null;
            }

            @Override
            public DvmObject<?> callStaticObjectMethodV(BaseVM bvm, DvmClass c, DvmMethod m, VaList a) {
                System.out.println("== [Java-static] " + m.getSignature());
                if (m.getSignature().contains("classLoader()")) return classLoaderProxy;
                return null;
            }

            // ================= 构造器 =================
            @Override
            public DvmObject<?> newObject(BaseVM bvm, DvmClass c, DvmMethod m, VarArg a) {
                return handleNew(bvm, m, objArg(a, 0), strArg(a, 1));
            }

            @Override
            public DvmObject<?> newObjectV(BaseVM bvm, DvmClass c, DvmMethod m, VaList a) {
                return handleNew(bvm, m, objArg(a, 0), strArg(a, 1));
            }

            // ================= int =================
            @Override
            public int callIntMethod(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VarArg a) {
                return handleInt(obj, m, objArg(a, 0), arg2Int(a, 1), arg2Int(a, 2));
            }

            @Override
            public int callIntMethodV(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VaList a) {
                return handleInt(obj, m, objArg(a, 0), arg2Int(a, 1), arg2Int(a, 2));
            }

            // ================= long =================
            @Override
            public long callLongMethod(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VarArg a) {
                System.out.println("== [Java-long] " + m.getSignature());
                File f = fileOf(obj);
                if (f != null && m.getSignature().contains("length()")) return f.length();
                return 0L;
            }

            @Override
            public long callLongMethodV(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VaList a) {
                System.out.println("== [Java-long] " + m.getSignature());
                File f = fileOf(obj);
                if (f != null && m.getSignature().contains("length()")) return f.length();
                if (f != null && m.getSignature().contains("lastModified()")) return f.lastModified();
                return 0L;
            }

            // ================= boolean =================
            @Override
            public boolean callBooleanMethod(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VarArg a) {
                return handleBool(obj, m);
            }

            @Override
            public boolean callBooleanMethodV(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VaList a) {
                return handleBool(obj, m);
            }

            // ================= void =================
            @Override
            public void callVoidMethod(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VarArg a) {
                handleVoid(obj, m, objArg(a, 0), arg2Int(a, 1), arg2Int(a, 2));
            }

            @Override
            public void callVoidMethodV(BaseVM bvm, DvmObject<?> obj, DvmMethod m, VaList a) {
                handleVoid(obj, m, objArg(a, 0), arg2Int(a, 1), arg2Int(a, 2));
            }
        });
        // 解密日志量大（每次 JNI 调用一行），默认关闭；排障时加 -Dguarddecrypt.verbose=true
        vm.setVerbose(Boolean.getBoolean("guarddecrypt.verbose"));

        DalvikModule dm = vm.loadLibrary(soFile, true);
        dm.callJNI_OnLoad(emulator);
        System.out.println("== JNI_OnLoad done");

        DvmClass dexNative = vm.resolveClass("com.github.catvod.spider.DexNative");
        DvmObject<?> context = vm.resolveClass("android/content/Context").newObject(null);

        System.out.println("== calling getLoader ...");
        DvmObject<?> loader = dexNative.callStaticJniMethodObject(emulator,
                "getLoader(Ljava/lang/Object;)Ljava/lang/Object;", context);
        System.out.println("== getLoader returned: " + loader);

        // 壳在 getLoader 内部完成解密：把明文载荷 zip 写到 codeCacheDir/sharedb/config.db，
        // 随后因写入校验失败会 delete 它 —— JNI 桥在 delete 前已备份为 config.db.saved。
        File payload = new File(workDir, "sharedb/config.db.saved");
        if (!payload.isFile() || payload.length() == 0) payload = new File(workDir, "sharedb/config.db");
        if (!payload.isFile() || payload.length() == 0) {
            System.err.println("[GuardDecryptor] payload not produced; workDir listing:");
            try {
                Files.walk(workDir.toPath()).forEach(p -> {
                    try {
                        System.err.println("   " + workDir.toPath().relativize(p) + "  " + Files.size(p) + " bytes");
                    } catch (Exception ignored) {
                    }
                });
            } catch (Exception ignored) {
            }
            System.exit(5);
            return;
        }

        File parent = outJar.getAbsoluteFile().getParentFile();
        if (parent != null) parent.mkdirs();
        File tmpOut = new File(parent, outJar.getName() + ".part");
        Files.copy(payload.toPath(), tmpOut.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        if (outJar.exists() && !outJar.delete()) {
            System.err.println("[GuardDecryptor] cannot replace " + outJar);
            System.exit(6);
            return;
        }
        if (!tmpOut.renameTo(outJar)) {
            Files.copy(tmpOut.toPath(), outJar.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            tmpOut.delete();
        }
        System.out.println("[GuardDecryptor] payload written: " + outJar.getAbsolutePath()
                + " (" + outJar.length() + " bytes)");
        // 临时工作目录尽量清理；残留不影响正确性
        try {
            deleteTree(stamp);
        } catch (Throwable ignored) {
        }
        System.exit(0);
    }

    /**
     * 按顺序返回第一个存在的非空文件。
     * 用于同时兼容 ftyguard 与 wexguard 两套壳：它们的资源命名只差前缀，
     * 解密流程与 {@code DexNative.getLoader(Context)} 入口完全一致。
     */
    private static File pick(File stage, String... relatives) {
        for (String rel : relatives) {
            File f = new File(stage, rel);
            if (f.isFile() && f.length() > 0) {
                return f;
            }
        }
        return null;
    }

    /**
     * 把壳 jar（zip 容器，后缀可能是 .txt/.jpg）里的条目解到 staging 目录。
     * 只取解密需要的 assets/*，避免把 36 KB 的壳 dex 也铺出来。
     */
    private static void extract(File shellJar, File stage) throws Exception {
        try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(shellJar)) {
            java.util.Enumeration<? extends java.util.zip.ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                java.util.zip.ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                if (!name.startsWith("assets/") || name.endsWith("/")) continue;
                File out = new File(stage, name);
                File parent = out.getParentFile();
                if (parent != null) parent.mkdirs();
                try (InputStream in = zip.getInputStream(entry);
                     OutputStream os = new java.io.FileOutputStream(out)) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) != -1) os.write(buf, 0, n);
                }
            }
        }
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }

    static void dumpHead(String rel, File f) {
        if (!f.isFile() || f.length() == 0) {
            System.out.println("== " + rel + ": 不存在或为空");
            return;
        }
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] head = new byte[32];
            int n = in.read(head);
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < n; i++) sb.append(String.format("%02x ", head[i]));
            String ascii = new String(head, 0, Math.min(n, 8), java.nio.charset.StandardCharsets.ISO_8859_1)
                    .replaceAll("[^\\x20-\\x7e]", ".");
            System.out.println("== " + rel + " (" + f.length() + " bytes) head: " + sb);
            System.out.println("== " + rel + " magic-ascii: [" + ascii + "]");
        } catch (Exception e) {
            System.out.println("== " + rel + " head read failed: " + e);
        }
    }

    // ==================== helpers ====================

    static Object objArg(VarArg a, int i) {
        try {
            DvmObject<?> o = a.getObjectArg(i);
            return o == null ? null : o.getValue();
        } catch (Throwable t) {
            return null;
        }
    }

    static Object objArg(VaList a, int i) {
        try {
            DvmObject<?> o = a.getObjectArg(i);
            return o == null ? null : o.getValue();
        } catch (Throwable t) {
            return null;
        }
    }

    static String strArg(VarArg a, int i) {
        Object v = objArg(a, i);
        return v == null ? null : v.toString();
    }

    static String strArg(VaList a, int i) {
        Object v = objArg(a, i);
        return v == null ? null : v.toString();
    }

    static int arg2Int(VarArg a, int i) {
        try {
            return a.getIntArg(i);
        } catch (Throwable t) {
            return 0;
        }
    }

    static int arg2Int(VaList a, int i) {
        try {
            return a.getIntArg(i);
        } catch (Throwable t) {
            return 0;
        }
    }

    static File fileOf(DvmObject<?> obj) {
        Object v = obj.getValue();
        return v instanceof File ? (File) v : null;
    }

    static DvmObject<?> newFileObj(BaseVM bvm, File f) {
        return fileCls.newObject(f);
    }

    // ==================== handlers ====================

    static DvmObject<?> handleObj(BaseVM bvm, DvmObject<?> obj, DvmMethod m, Object arg0, String arg1) {
        String sig = m.getSignature();
        System.out.println("== [Java] " + sig + (arg0 != null ? "   arg0=" + arg0 : ""));
        if (sig.contains("getClassLoader()")) return classLoaderProxy;
        if (sig.contains("getCacheDir()") || sig.contains("getCodeCacheDir()") || sig.contains("getFilesDir()")) {
            return newFileObj(bvm, workDir);
        }
        if (obj.getValue() instanceof File) {
            File f = (File) obj.getValue();
            if (sig.endsWith("getAbsolutePath()Ljava/lang/String;")) return new StringObject(bvm, f.getAbsolutePath());
            if (sig.endsWith("getPath()Ljava/lang/String;")) return new StringObject(bvm, f.getPath());
            if (sig.endsWith("getName()Ljava/lang/String;")) return new StringObject(bvm, f.getName());
            if (sig.endsWith("getParent()Ljava/lang/String;")) return new StringObject(bvm, f.getParent() == null ? "" : f.getParent());
            if (sig.endsWith("getParentFile()Ljava/io/File;")) return f.getParentFile() == null ? null : newFileObj(bvm, f.getParentFile());
            if (sig.endsWith("listFiles()[Ljava/io/File;")) return null; // TODO 按需
        }
        if (sig.contains("ClassLoader->getResourceAsStream")) {
            System.out.println("== [Java] resource requested: " + arg0);
            if (arg0 != null && (String.valueOf(arg0).contains("shinidie") || String.valueOf(arg0).endsWith(".guard"))) {
                return byteArrayInputStreamCls.newObject(new ByteArrayInputStream(guardData));
            }
            return null;
        }
        return null;
    }

    static DvmObject<?> handleNew(BaseVM bvm, DvmMethod m, Object arg0, String arg1) {
        String sig = m.getSignature();
        System.out.println("== [Java-new] " + sig + (arg0 != null ? "   arg0=" + arg0 : "") + (arg1 != null ? "   arg1=" + arg1 : ""));
        try {
            if (sig.startsWith("java/io/File->")) {
                if (arg0 instanceof File && arg1 != null) return newFileObj(bvm, new File((File) arg0, arg1));
                if (arg1 != null) return newFileObj(bvm, new File(arg1));
                if (arg0 instanceof String) return newFileObj(bvm, new File((String) arg0));
            }
            if (sig.startsWith("java/io/FileInputStream->")) {
                if (arg0 instanceof File) return fileInputStreamCls.newObject(new FileInputStream((File) arg0));
                if (arg1 != null) return fileInputStreamCls.newObject(new FileInputStream(arg1));
                if (arg0 instanceof String) return fileInputStreamCls.newObject(new FileInputStream((String) arg0));
            }
            if (sig.startsWith("java/io/FileOutputStream->")) {
                if (arg0 instanceof File) return fileOutputStreamCls.newObject(new FileOutputStream((File) arg0));
                if (arg1 != null) return fileOutputStreamCls.newObject(new FileOutputStream(arg1));
                if (arg0 instanceof String) return fileOutputStreamCls.newObject(new FileOutputStream((String) arg0));
            }
            if (sig.startsWith("dalvik/system/DexClassLoader->")) {
                System.out.println("== [Java] DexClassLoader created: dexPath=" + arg0 + " arg1=" + arg1);
                return bvm.resolveClass("dalvik/system/DexClassLoader").newObject("<DexClassLoader>");
            }
        } catch (Throwable t) {
            System.out.println("== [Java-new] FAILED: " + sig + " -> " + t);
        }
        return null;
    }

    static int handleInt(DvmObject<?> obj, DvmMethod m, Object arg0, int arg1, int arg2) {
        String sig = m.getSignature();
        System.out.println("== [Java-int] " + sig);
        try {
            if (obj.getValue() instanceof InputStream) {
                InputStream in = (InputStream) obj.getValue();
                if (sig.contains("read([B)I") && arg0 instanceof byte[]) {
                    int n = in.read((byte[]) arg0);
                    System.out.println("== [Java] InputStream.read -> " + n);
                    return n;
                }
                if (sig.contains("read([BII)I") && arg0 instanceof byte[]) {
                    int n = in.read((byte[]) arg0, arg1, arg2);
                    System.out.println("== [Java] InputStream.read(off,len) -> " + n);
                    return n;
                }
                if (sig.contains("available()")) return in.available();
            }
        } catch (Throwable t) {
            System.out.println("== [Java-int] FAILED: " + t);
            return -1;
        }
        return 0;
    }

    static boolean handleBool(DvmObject<?> obj, DvmMethod m) {
        String sig = m.getSignature();
        System.out.println("== [Java-bool] " + sig);
        File f = fileOf(obj);
        if (f != null) {
            if (sig.contains("exists()")) return f.exists();
            if (sig.contains("mkdirs()")) return f.mkdirs();
            if (sig.contains("mkdir()")) return f.mkdir();
            if (sig.contains("delete()")) {
                // 壳的失败分支会 delete 解密产物；删除前先备份一份，保证产物一定能留下来
                try {
                    if (f.isFile() && f.length() > 0) {
                        File bak = new File(f.getParentFile(), f.getName() + ".saved");
                        Files.copy(f.toPath(), bak.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                        System.out.println("== [Java] delete(): 已备份 " + bak.getAbsolutePath() + " (" + bak.length() + " bytes)");
                    }
                } catch (Throwable t) {
                    System.out.println("== [Java] delete(): 备份失败 " + t);
                }
                return f.delete();
            }
            if (sig.contains("isFile()")) return f.isFile();
            if (sig.contains("isDirectory()")) return f.isDirectory();
            if (sig.contains("canRead()")) return f.canRead();
            if (sig.contains("canWrite()")) return f.canWrite();
            // 关键修复：setReadOnly/setWritable 之前未实现→默认 false，
            // 导致壳把"设置只读失败"当成写入校验失败，走 exists→setWritable→delete→返回 null。
            // 真实 Android 上 setReadOnly()/setWritable(true) 成功时返回 true。
            if (sig.contains("setReadOnly()")) { System.out.println("== [Java] setReadOnly -> true(模拟成功)"); return true; }
            if (sig.contains("setWritable")) { System.out.println("== [Java] setWritable -> true(模拟成功)"); return true; }
        }
        return false;
    }

    static void handleVoid(DvmObject<?> obj, DvmMethod m, Object arg0, int arg1, int arg2) {
        String sig = m.getSignature();
        System.out.println("== [Java-void] " + sig);
        try {
            if (obj.getValue() instanceof OutputStream) {
                OutputStream out = (OutputStream) obj.getValue();
                if (sig.contains("write([BII)V") && arg0 instanceof byte[]) {
                    out.write((byte[]) arg0, arg1, arg2);
                    return;
                }
                if (sig.contains("close()")) {
                    out.close();
                    return;
                }
                if (sig.contains("flush()")) {
                    out.flush();
                }
            }
            if (obj.getValue() instanceof InputStream && sig.contains("close()")) {
                ((InputStream) obj.getValue()).close();
            }
        } catch (Throwable t) {
            System.out.println("== [Java-void] FAILED: " + t);
        }
    }
}
