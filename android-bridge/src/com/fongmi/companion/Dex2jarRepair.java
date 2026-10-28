package com.fongmi.companion;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * dex2jar 产物的结构化修补（只在转换后的 jar 上做，不碰原始 dex）。
 *
 * <p>目前只剩一类：十六进制字符串表还原把 {@code System.arraycopy} 的源 / 目标写反
 * （见 {@link #fixDecodeArraycopy}）。「NEW 被塌缩成父类」不在这里补，
 * 已在转换阶段由 {@link com.fongmi.companion.d2j.PreciseNewTransformer} 从源头保留真实分配类型。
 *
 * <p>安全性：只匹配严格形状，任一条件不满足就不动。修补失败只记日志并返回 false，
 * 调用方继续使用未修补的产物。
 */
public final class Dex2jarRepair {

    /** 日志里最多列出的修补条目数。 */
    private static final int LOG_LIMIT = 8;

    private Dex2jarRepair() {
    }

    /**
     * 尝试修补 {@code source} 并写到 {@code target}。
     *
     * @return true 表示写出了新文件；false 表示没必要或失败（调用方用原文件）
     */
    public static boolean repair(File source, File target) {
        try {
            Map<String, byte[]> others = new LinkedHashMap<>();
            Map<String, ClassNode> nodes = new LinkedHashMap<>();
            try (ZipFile zip = new ZipFile(source)) {
                Enumeration<? extends ZipEntry> it = zip.entries();
                while (it.hasMoreElements()) {
                    ZipEntry e = it.nextElement();
                    if (e.isDirectory()) continue;
                    byte[] data = readAll(zip, e);
                    if (e.getName().endsWith(".class")) {
                        ClassNode cn = new ClassNode();
                        new ClassReader(data).accept(cn, 0);
                        nodes.put(cn.name, cn);
                    } else {
                        others.put(e.getName(), data);
                    }
                }
            }

            List<String> log = new ArrayList<>();
            int arraySwaps = 0;
            for (ClassNode cn : nodes.values()) {
                for (MethodNode mn : cn.methods) {
                    arraySwaps += fixDecodeArraycopy(cn, mn, true, log);
                }
            }

            // 自检：换向后不应再残留「解码结果当 dest」的形状。残留说明上游换了写法，
            // 该类的字符串表仍会是全零 —— 必须显式报警，不能静默产出坏载荷。
            int leftover = 0;
            List<String> leftoverAt = new ArrayList<>();
            for (ClassNode cn : nodes.values()) {
                for (MethodNode mn : cn.methods) {
                    int n = fixDecodeArraycopy(cn, mn, false, log);
                    if (n > 0) {
                        leftover += n;
                        if (leftoverAt.size() < LOG_LIMIT) {
                            leftoverAt.add(cn.name + "." + mn.name + mn.desc);
                        }
                    }
                }
            }
            if (leftover > 0) {
                System.err.println("[Dex2jarRepair] 警告: 仍有 " + leftover
                        + " 处字符串表 arraycopy 疑似反向（形状未覆盖，相关类会解出全零）: " + leftoverAt);
            }

            if (arraySwaps == 0) {
                return false;
            }

            File tmp = new File(target.getParentFile(), target.getName() + ".tmp");
            try (ZipOutputStream out = new ZipOutputStream(new FileOutputStream(tmp))) {
                for (Map.Entry<String, byte[]> e : others.entrySet()) {
                    out.putNextEntry(new ZipEntry(e.getKey()));
                    out.write(e.getValue());
                    out.closeEntry();
                }
                for (ClassNode cn : nodes.values()) {
                    ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS);
                    cn.accept(cw);
                    out.putNextEntry(new ZipEntry(cn.name + ".class"));
                    out.write(cw.toByteArray());
                    out.closeEntry();
                }
            }
            Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
            System.out.println("[Dex2jarRepair] 修补完成: 字符串表 arraycopy 换向 " + arraySwaps
                    + " 处 -> " + target.getName());
            for (String line : log) {
                System.out.println("[Dex2jarRepair]   " + line);
            }
            return true;
        } catch (Throwable t) {
            System.err.println("[Dex2jarRepair] 跳过修补（失败，使用原产物）: " + t);
            return false;
        }
    }

    /**
     * 修正 dex2jar 把「字符串表解码结果」写成 {@code arraycopy} 源/目标颠倒的问题。
     *
     * <p>混淆壳的静态字符串表在 dex 里是「读一个静态 short[]」再 {@code System.arraycopy}
     * 到本地数组。dex2jar 的十六进制字符串还原把那个静态数组换成
     * {@code $d2j$hex$…$decode_S("hex")}，却把它塞进了<b>目标</b>参数位，于是产物变成：
     * <pre>
     *   short[] a = new short[N];                       // 全零
     *   System.arraycopy(a, 0, decode_S("hex"), 0, N);  // 把零拷进解码结果
     *   staticField = a;                                // 拿到的是全零
     * </pre>
     * 之后 {@code (char)(table[i] ^ key)} 恒等于 key，表现为 header 名/UA 全是同一个怪字符
     * （{@code Unexpected char 0x7d1 at 0 in header name}）。正确形态是把两个引用操作数换向：
     * <pre>
     *   LDC "hex"; INVOKESTATIC decode; ICONST_0; ALOAD a; ICONST_0; SIPUSH N; arraycopy
     * </pre>
     *
     * <p>只匹配严格形状：解码调用必须是本类的 {@code $d2j$hex$…$decode_*}，其前一个真实指令是
     * {@code LDC String}，其后紧跟两个常量再是 {@code System.arraycopy}，且源操作数是单条
     * 局部变量/静态字段装载。任一条件不满足就不动。
     */
    private static int fixDecodeArraycopy(ClassNode cn, MethodNode mn, boolean apply, List<String> log) {
        int changed = 0;
        for (AbstractInsnNode p = mn.instructions.getFirst(); p != null; p = p.getNext()) {
            if (p.getOpcode() != Opcodes.INVOKESTATIC || !(p instanceof MethodInsnNode)) continue;
            MethodInsnNode dec = (MethodInsnNode) p;
            if (!cn.name.equals(dec.owner) || !dec.name.startsWith("$d2j$hex$")
                    || !dec.name.contains("$decode_")) continue;
            if (!dec.desc.startsWith("(Ljava/lang/String;)")
                    || !Type.getReturnType(dec.desc).getDescriptor().startsWith("[")) continue;

            AbstractInsnNode hex = prevReal(dec);
            if (!(hex instanceof LdcInsnNode) || !(((LdcInsnNode) hex).cst instanceof String)) continue;

            AbstractInsnNode destPos = nextReal(dec);
            AbstractInsnNode len = nextReal(destPos);
            AbstractInsnNode copy = nextReal(len);
            if (!isIntConst(destPos) || !isIntConst(len)) continue;
            if (copy == null || copy.getOpcode() != Opcodes.INVOKESTATIC
                    || !(copy instanceof MethodInsnNode)) continue;
            MethodInsnNode ac = (MethodInsnNode) copy;
            if (!"java/lang/System".equals(ac.owner) || !"arraycopy".equals(ac.name)) continue;

            AbstractInsnNode srcPos = prevReal(hex);
            AbstractInsnNode srcRef = prevReal(srcPos);
            if (!isIntConst(srcPos) || !isSimpleRefLoad(srcRef)) continue;
            Object cst = ((LdcInsnNode) hex).cst;
            int srcOp = srcRef.getOpcode();
            int srcVar = srcRef instanceof VarInsnNode ? ((VarInsnNode) srcRef).var : -1;
            String srcField = srcRef instanceof FieldInsnNode ? ((FieldInsnNode) srcRef).name : null;
            String srcFieldOwner = srcRef instanceof FieldInsnNode ? ((FieldInsnNode) srcRef).owner : null;
            String srcFieldDesc = srcRef instanceof FieldInsnNode ? ((FieldInsnNode) srcRef).desc : null;

            if (!apply) {
                // 自检模式：只统计，不改字节码
                changed++;
                p = copy;
                continue;
            }

            // 换向：[srcRef][srcPos][hex][decode] -> LDC hex; decode; [srcPos]; srcRef
            mn.instructions.remove(dec);
            mn.instructions.remove(hex);
            AbstractInsnNode newHex = new LdcInsnNode(cst);
            mn.instructions.set(srcRef, newHex);
            mn.instructions.insert(newHex, new MethodInsnNode(Opcodes.INVOKESTATIC,
                    dec.owner, dec.name, dec.desc, dec.itf));
            AbstractInsnNode reload;
            if (srcField != null) {
                reload = new FieldInsnNode(Opcodes.GETSTATIC, srcFieldOwner, srcField, srcFieldDesc);
            } else {
                reload = new VarInsnNode(srcOp, srcVar);
            }
            // 目标引用必须在 srcPos 之后入栈：src, srcPos, dest, destPos, length
            mn.instructions.insert(srcPos, reload);

            changed++;
            if (log.size() < LOG_LIMIT) {
                log.add("arraycopy 换向 in " + cn.name + "." + mn.name + mn.desc
                        + "（" + dec.name + " len=" + ((LdcInsnNode) hex).cst.toString().length() / 4 + "）");
            }
            p = reload;
        }
        return changed;
    }

    private static AbstractInsnNode nextReal(AbstractInsnNode from) {
        if (from == null) return null;
        for (AbstractInsnNode q = from.getNext(); q != null; q = q.getNext()) {
            if (q.getOpcode() >= 0) return q;
        }
        return null;
    }

    private static AbstractInsnNode prevReal(AbstractInsnNode from) {
        if (from == null) return null;
        for (AbstractInsnNode q = from.getPrevious(); q != null; q = q.getPrevious()) {
            if (q.getOpcode() >= 0) return q;
        }
        return null;
    }

    private static boolean isIntConst(AbstractInsnNode n) {
        if (n == null) return false;
        int op = n.getOpcode();
        if (op >= Opcodes.ICONST_M1 && op <= Opcodes.ICONST_5) return true;
        if (op == Opcodes.BIPUSH || op == Opcodes.SIPUSH) return true;
        return op == Opcodes.LDC && n instanceof LdcInsnNode
                && ((LdcInsnNode) n).cst instanceof Integer;
    }

    private static boolean isSimpleRefLoad(AbstractInsnNode n) {
        if (n == null) return false;
        int op = n.getOpcode();
        // ASM 把 ALOAD_0..ALOAD_3 归一化为 ALOAD + var 槽位
        if (op == Opcodes.ALOAD) return true;
        return op == Opcodes.GETSTATIC || op == Opcodes.GETFIELD;
    }

    private static byte[] readAll(ZipFile zip, ZipEntry e) throws Exception {
        try (InputStream in = zip.getInputStream(e)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }
}
