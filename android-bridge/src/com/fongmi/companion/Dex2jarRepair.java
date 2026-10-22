package com.fongmi.companion;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * dex2jar 产物的结构化修补（只在转换后的 jar 上做，不碰原始 dex）。
 *
 * <p>背景：dex2jar 对混淆代码会产出两类**必然抛错**的字节码：
 * <ol>
 *   <li>{@code NEW} 指向 abstract/interface 类 → 运行时 {@code InstantiationError}；</li>
 *   <li>子类的构造器整个丢失（转换日志里的 {@code can't get operand(s) for invoke-direct}），
 *       于是即便把 {@code NEW} 改对，也找不到可调用的 {@code <init>}。</li>
 * </ol>
 *
 * <p>修补规则（纯结构，不含任何站点/壳名）：
 * <ul>
 *   <li><b>定向</b>：若 {@code NEW A} 之后紧跟 {@code A.<init>}，且随后把结果存进一个
 *       声明类型为 {@code D} 的字段，而 {@code D} 是 {@code A} 的具体子类，
 *       则把 {@code NEW A} / {@code A.<init>} 改成 {@code D}。字段类型就是原作者的类型意图，
 *       比「猜唯一子类」可靠（实测 {@code b1/g} 有两个具体子类）。</li>
 *   <li><b>补构造器</b>：若 {@code D} 没有任何 {@code <init>}，而其父类只有一个构造器，
 *       则生成一个同签名的转发构造器（{@code aload_0; 参数; invokespecial 父.<init>; return}）。</li>
 * </ul>
 *
 * <p>安全性：任一条件不满足就**不修**，保持原状（宁可维持现状，也不猜错类型）。
 * 修补失败只记日志并返回 false，调用方继续使用未修补的产物。
 */
public final class Dex2jarRepair {

    /** 指令窗口：NEW → <init> 之间允许的真实指令数。 */
    private static final int CTOR_WINDOW = 24;
    /** <init> → 字段存储 之间允许的真实指令数（构造器调用后通常立刻存储）。 */
    private static final int STORE_WINDOW = 12;
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
            Map<String, byte[]> entries = new LinkedHashMap<>();
            Map<String, byte[]> others = new LinkedHashMap<>();
            try (ZipFile zip = new ZipFile(source)) {
                Enumeration<? extends ZipEntry> it = zip.entries();
                while (it.hasMoreElements()) {
                    ZipEntry e = it.nextElement();
                    if (e.isDirectory()) continue;
                    byte[] data = readAll(zip, e);
                    if (e.getName().endsWith(".class")) {
                        entries.put(e.getName(), data);
                    } else {
                        others.put(e.getName(), data);
                    }
                }
            }

            Map<String, ClassNode> nodes = new LinkedHashMap<>();
            for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                ClassNode cn = new ClassNode();
                new ClassReader(e.getValue()).accept(cn, 0);
                nodes.put(cn.name, cn);
            }

            Map<String, String> superOf = new HashMap<>();
            Map<String, Integer> accessOf = new HashMap<>();
            Map<String, Set<String>> ctors = new HashMap<>();
            Map<String, Map<String, String>> fields = new HashMap<>();
            for (ClassNode cn : nodes.values()) {
                superOf.put(cn.name, cn.superName);
                accessOf.put(cn.name, cn.access);
                Set<String> ctorSet = new LinkedHashSet<>();
                for (MethodNode mn : cn.methods) {
                    if ("<init>".equals(mn.name)) ctorSet.add(mn.desc);
                }
                ctors.put(cn.name, ctorSet);
                Map<String, String> fieldMap = new HashMap<>();
                for (org.objectweb.asm.tree.FieldNode fn : cn.fields) {
                    fieldMap.put(fn.name, fn.desc);
                }
                fields.put(cn.name, fieldMap);
            }

            List<String> log = new ArrayList<>();
            Map<String, String> synthesized = new LinkedHashMap<>();
            int rewrites = 0;
            int arraySwaps = 0;

            for (ClassNode cn : nodes.values()) {
                for (MethodNode mn : cn.methods) {
                    rewrites += rewriteAbstractNew(cn, mn, superOf, accessOf, fields,
                            ctors, synthesized, log);
                    arraySwaps += fixDecodeArraycopy(cn, mn, true, log);
                }
            }

            int addedCtors = 0;
            for (Map.Entry<String, String> e : synthesized.entrySet()) {
                ClassNode cn = nodes.get(e.getKey());
                String desc = e.getValue();
                if (cn == null || ctors.getOrDefault(cn.name, java.util.Collections.emptySet()).contains(desc)) {
                    continue;
                }
                if (addForwardingCtor(cn, desc, superOf, ctors)) {
                    addedCtors++;
                    if (log.size() < LOG_LIMIT) {
                        log.add("ctor " + cn.name + "." + desc + "（转发到 " + cn.superName + "）");
                    }
                }
            }

            // 自检：换向后不应再残留「解码结果当 dest」的形状。残留说明上游换了写法，
            // 该类的字符串表仍会是全零 —— 必须显式报警，不能静默产出坏载荷。
            int leftover = 0;
            java.util.List<String> leftoverAt = new java.util.ArrayList<>();
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

            if (rewrites == 0 && addedCtors == 0 && arraySwaps == 0) {
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
            System.out.println("[Dex2jarRepair] 修补完成: NEW(abstract)->具体子类 " + rewrites
                    + " 处，补构造器 " + addedCtors + " 个，字符串表 arraycopy 换向 " + arraySwaps
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
     * 说明：曾尝试为「被转换器丢掉的 TypeToken 匿名子类」补一个 {@code <Object>} 泛型子类。
     * 实测（newwex 99 站）：它只把 29 个站的报错从 {@code IllegalStateException: TypeToken}
     * 换成 {@code ClassCastException: a1.r -> LinkedHashMap}，**覆盖率毫无变化**。
     * 因为原始泛型实参无法从 dex 恢复，任何猜测都可能把类型改错，故不纳入发货范围。
     */

    /** 在单个方法里做「NEW 抽象类 → 字段声明类型」的定向改写。 */
    private static int rewriteAbstractNew(ClassNode cn, MethodNode mn,
                                          Map<String, String> superOf, Map<String, Integer> accessOf,
                                          Map<String, Map<String, String>> fields,
                                          Map<String, Set<String>> ctors,
                                          Map<String, String> synthesized,
                                          List<String> log) {
        int changed = 0;
        for (AbstractInsnNode p = mn.instructions.getFirst(); p != null; p = p.getNext()) {
            if (!(p instanceof TypeInsnNode) || p.getOpcode() != Opcodes.NEW) continue;
            TypeInsnNode newInsn = (TypeInsnNode) p;
            String abstractOwner = newInsn.desc;
            if (!isAbstract(abstractOwner, accessOf)) continue;

            MethodInsnNode ctorInsn = findCtor(newInsn, abstractOwner);
            if (ctorInsn == null) continue;

            FieldInsnNode store = findStore(ctorInsn);
            if (store == null || store.desc == null || !store.desc.startsWith("L")) continue;

            String target = Type.getType(store.desc).getInternalName();
            if (target.equals(abstractOwner)) continue;
            if (!isConcreteSubclass(target, abstractOwner, superOf, accessOf)) continue;

            // 目标类型必须存在同名构造器，否则先登记待补
            Set<String> targetCtors = ctors.get(target);
            if (targetCtors == null) continue;
            if (!targetCtors.contains(ctorInsn.desc)) {
                if (countSuperCtors(target, superOf, ctors) != 1) continue;
                synthesized.put(target, ctorInsn.desc);
            }

            newInsn.desc = target;
            ctorInsn.owner = target;
            changed++;
            if (log.size() < LOG_LIMIT) {
                log.add("NEW " + abstractOwner + " -> " + target + "（字段 "
                        + store.name + ":" + store.desc + "） in "
                        + cn.name + "." + mn.name + mn.desc);
            }
        }
        return changed;
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

    private static MethodInsnNode findCtor(AbstractInsnNode from, String owner) {
        int budget = CTOR_WINDOW;
        for (AbstractInsnNode q = from.getNext(); q != null && budget > 0; q = q.getNext()) {
            if (q.getOpcode() < 0) continue;            // label / frame / line
            budget--;
            if (q.getOpcode() == Opcodes.INVOKESPECIAL && q instanceof MethodInsnNode) {
                MethodInsnNode m = (MethodInsnNode) q;
                if ("<init>".equals(m.name) && owner.equals(m.owner)) return m;
            }
        }
        return null;
    }

    private static FieldInsnNode findStore(AbstractInsnNode from) {
        int budget = STORE_WINDOW;
        for (AbstractInsnNode q = from.getNext(); q != null && budget > 0; q = q.getNext()) {
            if (q.getOpcode() < 0) continue;
            budget--;
            if (q.getOpcode() == Opcodes.PUTSTATIC || q.getOpcode() == Opcodes.PUTFIELD) {
                return (FieldInsnNode) q;
            }
        }
        return null;
    }

    private static boolean isAbstract(String name, Map<String, Integer> accessOf) {
        Integer acc = accessOf.get(name);
        if (acc == null) return false;   // 外部类（java.* / 依赖 jar），不要动
        return (acc & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_INTERFACE)) != 0;
    }

    private static boolean isConcreteSubclass(String candidate, String base,
                                             Map<String, String> superOf, Map<String, Integer> accessOf) {
        Integer acc = accessOf.get(candidate);
        if (acc == null) return false;
        if ((acc & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_INTERFACE)) != 0) return false;
        String cur = candidate;
        for (int guard = 0; guard < 64 && cur != null; guard++) {
            String sup = superOf.get(cur);
            if (base.equals(sup)) return true;
            cur = sup;
        }
        return false;
    }

    private static int countSuperCtors(String name, Map<String, String> superOf,
                                       Map<String, Set<String>> ctors) {
        String sup = superOf.get(name);
        if (sup == null) return 0;
        Set<String> descs = ctors.get(sup);
        return descs == null ? 0 : descs.size();
    }

    /** 生成转发构造器：{@code aload_0; 参数; invokespecial 父.<init>; return}。 */
    private static boolean addForwardingCtor(ClassNode cn, String desc,
                                             Map<String, String> superOf,
                                             Map<String, Set<String>> ctors) {
        String sup = cn.superName;
        if (sup == null) return false;
        Set<String> supCtors = ctors.get(sup);
        if (supCtors == null || supCtors.size() != 1 || !supCtors.contains(desc)) return false;

        MethodNode mn = new MethodNode(Opcodes.ACC_PUBLIC, "<init>", desc, null, null);
        mn.instructions.add(new VarInsnNode(Opcodes.ALOAD, 0));
        int slot = 1;
        for (Type arg : Type.getArgumentTypes(desc)) {
            mn.instructions.add(new VarInsnNode(arg.getOpcode(Opcodes.ILOAD), slot));
            slot += arg.getSize();
        }
        mn.instructions.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, sup, "<init>", desc, false));
        mn.instructions.add(new InsnNode(Opcodes.RETURN));
        mn.maxStack = slot;
        mn.maxLocals = slot;
        cn.methods.add(mn);
        ctors.computeIfAbsent(cn.name, k -> new LinkedHashSet<>()).add(desc);
        return true;
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
