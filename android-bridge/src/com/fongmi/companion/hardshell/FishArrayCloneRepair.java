package com.fongmi.companion.hardshell;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.*;

/** 此载荷通过反射调用数组 clone；标准 JVM 不会在数组的声明方法中暴露它。 */
final class FishArrayCloneRepair {
    private static final String SOURCE_SHA256 = "c2b98f1bcd472bc7ff1de50523afae8732c00323fc45e450ec0329037a8dd557";
    private static final String OWNER = "np/protect/\u06df\u06e4\u06e3\u06df\u06e2";
    private static final String DESC = "(ILjava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;";
    private static final String STAMP = "-fish-arrayclone-v1";

    private FishArrayCloneRepair() {}

    static String stamp(File original) { return matches(original) ? STAMP : ""; }

    static boolean repair(File converted, File original) {
        if (!matches(original)) return false;
        Path pending = converted.toPath().resolveSibling(converted.getName() + ".fish-clone.tmp");
        boolean patched = false;
        try {
            try (ZipFile source = new ZipFile(converted);
                 ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(pending))) {
                var entries = source.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    byte[] bytes;
                    try (var input = source.getInputStream(entry)) { bytes = input.readAllBytes(); }
                    if (entry.getName().equals(OWNER + ".class")) {
                        bytes = patch(bytes);
                        patched = true;
                    }
                    output.putNextEntry(new ZipEntry(entry.getName()));
                    output.write(bytes);
                    output.closeEntry();
                }
            }
            if (!patched) throw new IllegalStateException("Fish 已验证载荷缺少数组克隆分派器");
            Files.move(pending, converted.toPath(), StandardCopyOption.REPLACE_EXISTING);
            System.out.println("[Fish/repair] 已补齐真实 byte[].clone 调用");
            return true;
        } catch (IOException failure) {
            throw new IllegalStateException("Fish 数组克隆兼容修补失败", failure);
        } finally {
            try { Files.deleteIfExists(pending); } catch (IOException ignored) {}
        }
    }

    private static byte[] patch(byte[] bytes) {
        ClassNode type = new ClassNode();
        new ClassReader(bytes).accept(type, 0);
        MethodNode method = type.methods.stream().filter(m -> m.name.equals("n") && m.desc.equals(DESC))
                .findFirst().orElseThrow(() -> new IllegalStateException("Fish 数组克隆分派方法缺失"));
        if (!type.name.equals(OWNER) || (method.access & Opcodes.ACC_STATIC) == 0
                || method.instructions.size() < 100) throw new IllegalStateException("Fish 数组克隆分派结构不符");
        int switches = 0;
        for (AbstractInsnNode instruction : method.instructions) {
            if (instruction instanceof LookupSwitchInsnNode) switches++;
            if (instruction instanceof MethodInsnNode call && call.owner.equals("[B") && call.name.equals("clone")) {
                throw new IllegalStateException("Fish 数组克隆兼容修补不能重复应用");
            }
        }
        if (switches != 1) throw new IllegalStateException("Fish 数组克隆分派表不符");
        // 13599 对应原分派表 [B.clone()Object，其余编号保留原路径。
        InsnList prefix = new InsnList();
        LabelNode original = new LabelNode();
        prefix.add(new VarInsnNode(Opcodes.ILOAD, 0));
        prefix.add(new IntInsnNode(Opcodes.SIPUSH, 13599));
        prefix.add(new JumpInsnNode(Opcodes.IF_ICMPNE, original));
        prefix.add(new VarInsnNode(Opcodes.ALOAD, 1));
        prefix.add(new TypeInsnNode(Opcodes.CHECKCAST, "[B"));
        prefix.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL, "[B", "clone", "()Ljava/lang/Object;", false));
        prefix.add(new InsnNode(Opcodes.ARETURN));
        prefix.add(original);
        prefix.add(new FrameNode(Opcodes.F_SAME, 0, null, 0, null));
        method.instructions.insert(prefix);
        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        type.accept(writer);
        return writer.toByteArray();
    }

    private static boolean matches(File original) {
        if (original == null || !original.isFile()) return false;
        try { return SOURCE_SHA256.equals(FishNativeService.sha256(original)); }
        catch (IOException failure) { throw new IllegalStateException("Fish 载荷指纹读取失败", failure); }
    }
}
