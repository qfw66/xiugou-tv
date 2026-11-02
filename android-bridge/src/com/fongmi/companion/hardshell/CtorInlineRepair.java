package com.fongmi.companion.hardshell;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

import java.io.File;
import java.io.FileOutputStream;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * 修补「ART 构造器内联被 dex2jar 塌缩」这一类坍塌。与源无关：任何加固载荷只要经
 * {@code PreciseDex2jar} 转换后出现同种形态，就直接适用。
 *
 * <p>与既有 {@code Dex2jarRepair}（十六进制字符串表 arraycopy 换向）互补，两者按需串行。
 *
 * <h3>一 · {@code <init>} 归属塌缩</h3>
 * <pre>
 *   new  T
 *   astore 7 / dup
 *   ...
 *   aload 7
 *   invokespecial Super."&lt;init&gt;":()V      ← 归属被塌到父类（含 java/lang/Object）
 * </pre>
 * JVM 铁律：{@code new T} 产生的未初始化值**只能**由 {@code T.&lt;init&gt;} 消费，否则
 * {@code VerifyError: Call to wrong <init> method}。修法按「未初始化值栈」追踪
 * （见 {@link #fixOwners}），把归属改回真实分配类型；目标类缺该描述符构造器时
 * 合成转发构造器 {@code T.&lt;init&gt;(D){super(D);}}（这正是被 ART 内联掉的那个）。
 *
 * <h3>二 · super() 塌到间接祖先</h3>
 * <pre>
 *   class C extends Y extends … extends Enum
 *   C.&lt;init&gt;(String,int): aload_0; aload_1; iload_2; invokespecial Enum."&lt;init&gt;"(String,int)V
 * </pre>
 * 对 {@code uninitializedThis} 的 {@code invokespecial} 只允许指向自身或**直接父类**，
 * 指到更高的祖先必然 {@code VerifyError: Bad <init> method call}。这类字节码不存在
 * 「原本能跑」的情形，一律纠正到直接父类；中间层缺构造器就沿父类链逐级补转发器
 * （见 {@link #fixSuperCtorCalls} / {@link #ensureCtorChain}）。
 *
 * <p>注意判据不能用「紧邻上一条是 aload_0」：带参 super() 的紧邻指令是参数压栈。
 *
 * <h3>三 · new 与 invokespecial 各自塌到祖先</h3>
 * 此时 {@code new T} 与 {@code T.<init>} 自洽，改归属无从下手；唯一幸存的真类型证据是
 * **下游用点**：字段描述符、方法返回类型、{@code checkcast} 目标。若用点类型 {@code U}
 * 是 {@code T} 的真子类，说明真类型是 {@code U}，把 {@code new}/{@code invokespecial}
 * 一起抬回（见 {@link #widenAllocatedTypes}）。
 *
 * <h3>四 · StackMapTable 缺失</h3>
 * {@code PreciseDex2jar} 用 {@code COMPUTE_MAXS}，分支目标不写帧 → JVM 7+ 报
 * {@code Expecting a stackmap frame}。修法：用 {@code COMPUTE_FRAMES} 重写。
 *
 * <p>这里有个必须避开的坑：{@code ClassWriter.getCommonSuperClass} 默认用**宿主**
 * 类加载器解析类型，载荷类在宿主上不存在，回退 {@code java/lang/Object} 会把汇合点的
 * 精确类型毁掉（实测 {@code FormBody + RequestBody → Object}，随后
 * {@code post(RequestBody)} 报 {@code not assignable}）。所以继承表必须把
 * **载荷 + 运行期 classpath 上全部 jar + JDK（反射兜底）** 一起收进来
 * （只读 superName，不加载不校验）。JDK 类在 jrt 文件系统里，classpath 扫描扫不到，
 * 必须靠 {@link #ensureKnown} 反射补齐——否则父类链走到 {@code java/lang/Enum} 就断，
 * 「补转发构造器链」会全数失败。
 *
 * <h3>五 · 处理顺序与幂等</h3>
 * 顺序固定为：{@code synthesizeCtors}（补齐无参构造器）→ {@code fixSuperCtorCalls}
 * （super() 归位）→ {@code rewriteCtorOwners}（归属纠正 + 抬回真类型，跑到不动点）。
 * 所有计数都为 0 时直接返回 false 且**不写盘**——未受影响的站点与修补链不存在时
 * 行为完全一致。
 */
public final class CtorInlineRepair implements PayloadRepair {

    /** profile {@code repair.ids} 里使用的 id。 */
    public static final String ID = "ctor-inline";

    private final Map<String, String> supers = new HashMap<>();
    private final Map<String, Set<String>> ctors = new HashMap<>();
    private final Map<String, ClassNode> nodes = new LinkedHashMap<>();
    private final Map<String, byte[]> others = new LinkedHashMap<>();
    /** {@code new T} 指令 → 初始化它的 {@code invokespecial <init>}，供"抬回真类型"用。 */
    private final Map<TypeInsnNode, MethodInsnNode> ctorOf = new HashMap<>();

    private int synthesizedCtors;
    private int rewrittenOwners;
    private int widenedAllocs;
    private int fixedSuperCalls;
    private int rebuiltClasses;
    private int keptClasses;

    @Override
    public int version() {
        // 3 = 合成缺失无参构造器 + super() 纠正 + 归属纠正 + 补帧（第三版，VerifyError 0/589）
        return 3;
    }

    @Override
    public String id() {
        return ID;
    }

    @Override
    public boolean repair(File converted) {
        if (converted == null || !converted.isFile() || converted.length() == 0) return false;
        File tmp = new File(converted.getParentFile(), converted.getName() + ".repair.tmp");
        try {
            CtorInlineRepair fixer = new CtorInlineRepair();
            fixer.load(converted);
            fixer.synthesizeCtors();
            fixer.fixSuperCtorCalls();
            fixer.rewriteCtorOwners();
            if (fixer.synthesizedCtors == 0 && fixer.rewrittenOwners == 0
                    && fixer.widenedAllocs == 0 && fixer.fixedSuperCalls == 0) {
                System.out.println("[Hardshell/repair] 未检出构造器坍塌，保留原产物");
                return false;
            }
            fixer.write(tmp);
            if (!tmp.isFile() || tmp.length() == 0) {
                return false;
            }
            java.nio.file.Files.move(tmp.toPath(), converted.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            System.out.println("[Hardshell/repair] 修补完成: 合成构造器 " + fixer.synthesizedCtors
                    + " 处, super() 纠正 " + fixer.fixedSuperCalls
                    + " 处, 归属纠正 " + fixer.rewrittenOwners
                    + " 处, 抬回真类型 " + fixer.widenedAllocs + " 处, 补帧 "
                    + fixer.rebuiltClasses + "/" + (fixer.rebuiltClasses + fixer.keptClasses));
            return true;
        } catch (Throwable t) {
            System.err.println("[Hardshell/repair] 修补失败，保留原产物: " + t);
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            return false;
        }
    }

    private void load(File jar) throws Exception {
        scanHierarchy(jar, true);
        scanClasspath();
        try (ZipFile zip = new ZipFile(jar)) {
            var entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry e = entries.nextElement();
                if (e.isDirectory()) continue;
                byte[] data = zip.getInputStream(e).readAllBytes();
                if (!e.getName().endsWith(".class")) {
                    others.put(e.getName(), data);
                    continue;
                }
                ClassNode cn = new ClassNode();
                new ClassReader(data).accept(cn, 0);
                nodes.put(cn.name, cn);
            }
        }
    }

    /** 只读 class 头建继承表，顺带记下每个类的构造器描述符。 */
    private void scanHierarchy(File jar, boolean own) {
        try (ZipFile zip = new ZipFile(jar)) {
            var entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry e = entries.nextElement();
                if (e.isDirectory() || !e.getName().endsWith(".class")) continue;
                ClassNode cn = new ClassNode();
                new ClassReader(zip.getInputStream(e).readAllBytes()).accept(cn,
                        ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                if (cn.name == null) continue;
                if (!own && supers.containsKey(cn.name)) continue;
                supers.put(cn.name, cn.superName);
                Set<String> set = new HashSet<>();
                for (MethodNode mn : cn.methods) {
                    if ("<init>".equals(mn.name)) set.add(mn.desc);
                }
                if (own || !ctors.containsKey(cn.name)) ctors.put(cn.name, set);
            }
        } catch (Throwable ignored) {
        }
    }

    /** 运行期 classpath（含 companion fat jar 里摊平的 okhttp 等）也要进继承表。 */
    private void scanClasspath() {
        String cp = System.getProperty("java.class.path", "");
        for (String entry : cp.split(File.pathSeparator)) {
            if (entry == null || entry.trim().isEmpty()) continue;
            File f = new File(entry.trim());
            if (f.isFile() && f.getName().endsWith(".jar")) {
                scanHierarchy(f, false);
            } else if (f.isDirectory()) {
                scanDirHierarchy(f);
            }
        }
    }

    /**
     * 兜底解析 classpath 之外的类（JDK 在 jrt 文件系统里，{@link #scanClasspath()} 扫不到）。
     * 只用反射读父类与构造器签名，不触发初始化；解析不到就返回 false。
     */
    private boolean ensureKnown(String type) {
        if (type == null) return false;
        if (supers.containsKey(type)) return true;
        try {
            Class<?> c = Class.forName(type.replace('/', '.'), false,
                    CtorInlineRepair.class.getClassLoader());
            Class<?> sc = c.getSuperclass();
            supers.put(type, sc == null ? null : sc.getName().replace('.', '/'));
            Set<String> set = new HashSet<>();
            for (java.lang.reflect.Constructor<?> k : c.getDeclaredConstructors()) {
                set.add(descriptorOf(k.getParameterTypes()));
            }
            ctors.put(type, set);
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static String descriptorOf(Class<?>[] params) {
        StringBuilder sb = new StringBuilder("(");
        for (Class<?> p : params) {
            sb.append(p.isPrimitive() ? primitiveLetter(p) : "L" + p.getName().replace('.', '/') + ";");
        }
        return sb.append(")V").toString();
    }

    private static String primitiveLetter(Class<?> p) {
        if (p == void.class) return "V";
        if (p == boolean.class) return "Z";
        if (p == byte.class) return "B";
        if (p == char.class) return "C";
        if (p == short.class) return "S";
        if (p == int.class) return "I";
        if (p == long.class) return "J";
        if (p == float.class) return "F";
        return "D";
    }

    private void scanDirHierarchy(File dir) {
        File[] kids = dir.listFiles();
        if (kids == null) return;
        for (File kid : kids) {
            if (kid.isDirectory()) {
                scanDirHierarchy(kid);
            } else if (kid.getName().endsWith(".class")) {
                try {
                    ClassNode cn = new ClassNode();
                    new ClassReader(java.nio.file.Files.readAllBytes(kid.toPath())).accept(cn,
                            ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                    if (cn.name != null && !supers.containsKey(cn.name)) {
                        supers.put(cn.name, cn.superName);
                        Set<String> set = new HashSet<>();
                        for (MethodNode mn : cn.methods) {
                            if ("<init>".equals(mn.name)) set.add(mn.desc);
                        }
                        ctors.put(cn.name, set);
                    }
                } catch (Throwable ignored) {
                }
            }
        }
    }

    private void synthesizeCtors() {
        for (ClassNode cn : nodes.values()) {
            if (cn.name.equals("java/lang/Object")) continue;
            // 接口不能有构造器：补了会直接 ClassFormatError: illegal modifiers。
            if ((cn.access & Opcodes.ACC_INTERFACE) != 0) continue;
            Set<String> own = ctors.get(cn.name);
            if (own == null) {
                own = new HashSet<>();
                ctors.put(cn.name, own);
            }
            if (own.contains("()V")) continue;
            String superName = cn.superName == null ? "java/lang/Object" : cn.superName;
            Set<String> superCtors = ctors.get(superName);
            // 父类没有可用无参构造器时补出来也是坏链，跳过（外部/JDK 类型视为有）。
            if (superCtors != null && !superCtors.contains("()V")) continue;
            MethodNode mn = new MethodNode(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null);
            InsnList il = mn.instructions;
            il.add(new VarInsnNode(Opcodes.ALOAD, 0));
            il.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, superName, "<init>", "()V", false));
            il.add(new InsnNode(Opcodes.RETURN));
            mn.maxStack = 1;
            mn.maxLocals = 1;
            cn.methods.add(mn);
            own.add("()V");
            synthesizedCtors++;
        }
    }

    /**
     * 「super() 塌到 java/lang/Object」通道：{@code <init>} 里对 uninitializedThis 的
     * {@code invokespecial <init>} 按 JVM 规范只能指向自身或**直接父类**，指到别处必然
     * {@code VerifyError: Bad <init> method call}。这类字节码不存在"原本能跑"的情形，
     * 所以一律纠正到直接父类（父类缺该描述符时先由 {@link #synthesizeCtors()} 补 {@code ()V}）。
     */
    private void fixSuperCtorCalls() {
        for (ClassNode cn : nodes.values()) {
            if ((cn.access & Opcodes.ACC_INTERFACE) != 0) continue;
            String directSuper = cn.superName == null ? "java/lang/Object" : cn.superName;
            for (MethodNode mn : new java.util.ArrayList<>(cn.methods)) {
                if (!"<init>".equals(mn.name)) continue;
                String recentNew = null;
                for (AbstractInsnNode insn = mn.instructions.getFirst(); insn != null;
                        insn = insn.getNext()) {
                    int op = insn.getOpcode();
                    if (op == Opcodes.NEW && insn instanceof TypeInsnNode) {
                        recentNew = ((TypeInsnNode) insn).desc;
                        continue;
                    }
                    if (op != Opcodes.INVOKESPECIAL || !(insn instanceof MethodInsnNode)) continue;
                    MethodInsnNode mi = (MethodInsnNode) insn;
                    if (!"<init>".equals(mi.name)) continue;
                    boolean fromAllocation = mi.owner.equals(recentNew);
                    recentNew = null;
                    if (fromAllocation) continue;
                    if (mi.owner.equals(cn.name) || mi.owner.equals(directSuper)) continue;
                    // 接收者是 uninitializedThis（本构造器的 this）：JVM 只允许它被
                    // 自身或**直接父类**的 <init> 消费。塌到更高祖先时改回直接父类，
                    // 中间层缺链就先补转发构造器。参数个数无关，所以不靠"紧邻 aload_0"判定。
                    if (!isSuper(mi.owner, cn.name)) continue;
                    if (!ensureCtorChain(directSuper, mi.desc, 0)) continue;
                    mi.owner = directSuper;
                    fixedSuperCalls++;
                }
            }
        }
    }

    /**
     * 确保 {@code type} 或其某个祖先真正声明了 {@code desc}；中间缺的层级各自补一个
     * 「委托直接父类同描述符构造器」的转发器——正是被 ART 内联掉的那些
     * {@code X.&lt;init&gt;(D){super(D);}}。
     */
    private boolean ensureCtorChain(String type, String desc, int depth) {
        if (depth > 32) return false;
        ensureKnown(type);
        Set<String> declared = ctors.get(type);
        if (declared != null && declared.contains(desc)) return true;
        String sup = supers.get(type);
        if (sup == null) return false;
        if (!ensureCtorChain(sup, desc, depth + 1)) return false;
        return synthesizeForwarder(type, sup, desc);
    }

    private void rewriteCtorOwners() {
        // 归属纠正会改变 new/owner 的一致性，抬回真类型又会引入新的构造器；
        // 两者互相触发，跑到不动点（实测 2 轮收敛）。
        for (int iter = 0; iter < 4; iter++) {
            ctorOf.clear();
            int owners = 0;
            for (ClassNode cn : nodes.values()) {
                for (MethodNode mn : new java.util.ArrayList<>(cn.methods)) {
                    owners += fixOwners(mn);
                }
            }
            int widened = widenAllocatedTypes();
            rewrittenOwners += owners;
            widenedAllocs += widened;
            if (owners == 0 && widened == 0) break;
        }
    }

    /**
     * 「new / invokespecial 双双塌到父类」通道：按下游用点（字段描述符、返回类型、
     * checkcast）反推真类型，把 {@code new} 与 {@code <init>} 一起抬回子类。
     */
    private int widenAllocatedTypes() {
        if (ctorOf.isEmpty()) return 0;
        int count = 0;
        for (ClassNode cn : nodes.values()) {
            // 转发器可能被加进当前类，先快照方法表避免 ConcurrentModificationException。
            for (MethodNode mn : new java.util.ArrayList<>(cn.methods)) {
                count += widenMethod(mn);
            }
        }
        return count;
    }

    private int widenMethod(MethodNode mn) {
        int count = 0;
        Map<Integer, TypeInsnNode> localNew = new HashMap<>();
        String pending = null;
        TypeInsnNode pendingInsn = null;
        for (AbstractInsnNode insn = mn.instructions.getFirst(); insn != null; insn = insn.getNext()) {
            int op = insn.getOpcode();
            if (op == Opcodes.NEW && insn instanceof TypeInsnNode) {
                pending = ((TypeInsnNode) insn).desc;
                pendingInsn = (TypeInsnNode) insn;
                continue;
            }
            if (op == Opcodes.ASTORE && insn instanceof VarInsnNode) {
                int var = ((VarInsnNode) insn).var;
                if (pendingInsn != null) {
                    localNew.put(var, pendingInsn);
                } else {
                    localNew.remove(var);
                }
                pending = null;
                pendingInsn = null;
                continue;
            }
            if (op < 0) continue;

            String expected = null;
            AbstractInsnNode prev = insn.getPrevious();
            if ((op == Opcodes.PUTSTATIC || op == Opcodes.PUTFIELD)
                    && insn instanceof org.objectweb.asm.tree.FieldInsnNode) {
                expected = classOf(((org.objectweb.asm.tree.FieldInsnNode) insn).desc);
            } else if (op == Opcodes.ARETURN) {
                expected = classOf(mn.desc.substring(mn.desc.indexOf(')') + 1));
            } else if (op == Opcodes.CHECKCAST && insn instanceof TypeInsnNode) {
                expected = ((TypeInsnNode) insn).desc;
            }
            if (expected == null) continue;

            Integer var = sourceLocal(prev);
            if (var == null) continue;
            TypeInsnNode alloc = localNew.get(var);
            if (alloc == null || alloc.desc == null) continue;
            String allocated = alloc.desc;
            if (allocated.equals(expected)) continue;
            if (!isSuper(allocated, expected)) {
                continue;
            }
            if (!ensureKnown(expected)) continue;
            MethodInsnNode init = ctorOf.get(alloc);
            if (init == null) continue;
            // 只有"父类就是真类型的直接父类"时转发器才合法（JVM 要求
            // uninitializedThis 的 invokespecial 指向自身或直接父类）。
            if (!allocated.equals(supers.get(expected))) continue;
            // 真类型缺该描述符构造器时，先把整条父类链的转发器补齐。
            if (!ensureCtorChain(expected, init.desc, 0)) continue;
            alloc.desc = expected;
            init.owner = expected;
            count++;
        }
        return count;
    }

    /** 用点的值来自哪条 {@code aload}：取紧邻的上一条指令（用点前不会有别的消费）。 */
    private static Integer sourceLocal(AbstractInsnNode prev) {
        if (prev instanceof VarInsnNode && prev.getOpcode() == Opcodes.ALOAD) {
            return ((VarInsnNode) prev).var;
        }
        return null;
    }

    /** 描述符里的对象类型 → 内部名；非对象/数组返回 null。 */
    private static String classOf(String desc) {
        if (desc == null || desc.length() < 3) return null;
        if (desc.charAt(0) != 'L' || desc.charAt(desc.length() - 1) != ';') return null;
        return desc.substring(1, desc.length() - 1);
    }

    /**
     * 在 {@code type} 上补一个 {@code desc} 构造器，转发到 {@code superType} 同描述符构造器。
     * 返回是否补成功（该类必须在本载荷里）。
     */
    private boolean synthesizeForwarder(String type, String superType, String desc) {
        Set<String> own = ctors.get(type);
        if (own == null) {
            own = new HashSet<>();
            ctors.put(type, own);
        }
        if (own.contains(desc)) return true;
        ClassNode cn = nodes.get(type);
        if (cn == null) return false;
        MethodNode mn = new MethodNode(Opcodes.ACC_PUBLIC, "<init>", desc, null, null);
        InsnList il = mn.instructions;
        il.add(new VarInsnNode(Opcodes.ALOAD, 0));
        int slot = 1;
        int i = desc.indexOf('(') + 1;
        int end = desc.indexOf(')');
        while (i > 0 && i < end) {
            char c = desc.charAt(i);
            if (c == 'L') {
                int semi = desc.indexOf(';', i);
                if (semi < 0) break;
                il.add(new VarInsnNode(Opcodes.ALOAD, slot));
                slot += 1;
                i = semi + 1;
            } else if (c == '[') {
                int j = i;
                while (j < end && desc.charAt(j) == '[') j++;
                if (j < end && desc.charAt(j) == 'L') {
                    int semi = desc.indexOf(';', j);
                    if (semi < 0) break;
                    j = semi + 1;
                } else {
                    j++;
                }
                il.add(new VarInsnNode(Opcodes.ALOAD, slot));
                slot += 1;
                i = j;
            } else if (c == 'J' || c == 'D') {
                il.add(new VarInsnNode(c == 'J' ? Opcodes.LLOAD : Opcodes.DLOAD, slot));
                slot += 2;
                i++;
            } else if (c == 'F') {
                il.add(new VarInsnNode(Opcodes.FLOAD, slot));
                slot += 1;
                i++;
            } else {
                il.add(new VarInsnNode(Opcodes.ILOAD, slot));
                slot += 1;
                i++;
            }
        }
        il.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, superType, "<init>", desc, false));
        il.add(new InsnNode(Opcodes.RETURN));
        mn.maxStack = slot + 1;
        mn.maxLocals = slot;
        cn.methods.add(mn);
        own.add(desc);
        synthesizedCtors++;
        return true;
    }

    /**
     * 一个「尚未初始化的分配值」。类型直接读 {@code new} 指令的 desc，所以同一分配的
     * 多个副本（dup / 反复 aload）共享同一份类型，改写一处即全部生效。
     */
    private static final class Alloc {
        final TypeInsnNode insn;

        Alloc(TypeInsnNode insn) {
            this.insn = insn;
        }
    }

    /**
     * 按「未初始化值栈」把 {@code invokespecial <init>} 的 owner 纠正到真实分配类型。
     *
     * <p>这是对 JVM 语义的最小模拟：{@code new T} 压入一个未初始化值，{@code dup} 复制，
     * {@code astore/aload} 在局部变量与栈之间搬运，{@code <init>} 消费它。只有这样才能
     * 正确认出嵌套分配（{@code new X(new IOException(...))}）里外层的 {@code new X}，
     * 早期用「最近一次 new」的启发式在那里必错。
     */
    private int fixOwners(MethodNode mn) {
        int count = 0;
        Map<Integer, Alloc> locals = new HashMap<>();
        Set<TypeInsnNode> inited = new HashSet<>();
        java.util.ArrayDeque<Alloc> uninit = new java.util.ArrayDeque<>();

        for (AbstractInsnNode insn = mn.instructions.getFirst(); insn != null; insn = insn.getNext()) {
            int op = insn.getOpcode();
            if (op == Opcodes.NEW && insn instanceof TypeInsnNode) {
                uninit.addLast(new Alloc((TypeInsnNode) insn));
                if (uninit.size() > 32) uninit.pollFirst();
                continue;
            }
            if (op == Opcodes.DUP || op == Opcodes.DUP2
                    || op == Opcodes.DUP_X1 || op == Opcodes.DUP_X2) {
                if (!uninit.isEmpty()) {
                    uninit.addLast(new Alloc(uninit.peekLast().insn));
                    if (uninit.size() > 32) uninit.pollFirst();
                }
                continue;
            }
            if (op == Opcodes.ASTORE && insn instanceof VarInsnNode) {
                int var = ((VarInsnNode) insn).var;
                Alloc top = uninit.peekLast();
                if (top != null) {
                    uninit.pollLast();
                    locals.put(var, top);
                } else {
                    locals.remove(var);
                }
                continue;
            }
            if (op == Opcodes.ALOAD && insn instanceof VarInsnNode) {
                Alloc held = locals.get(((VarInsnNode) insn).var);
                // 已经构造完的对象不再是"未初始化值"，不能再被当成构造器接收者
                if (held != null && !inited.contains(held.insn)) {
                    uninit.addLast(new Alloc(held.insn));
                    if (uninit.size() > 32) uninit.pollFirst();
                }
                continue;
            }
            if (op == Opcodes.RETURN || op == Opcodes.ATHROW) {
                uninit.clear();
                continue;
            }
            if (op != Opcodes.INVOKESPECIAL || !(insn instanceof MethodInsnNode)) continue;
            MethodInsnNode mi = (MethodInsnNode) insn;
            if (!"<init>".equals(mi.name)) continue;

            // 优先消费"类型正好等于 owner"的那个未初始化值（本来就自洽）。
            Alloc picked = null;
            for (java.util.Iterator<Alloc> it = uninit.descendingIterator(); it.hasNext(); ) {
                Alloc a = it.next();
                if (mi.owner.equals(a.insn.desc)) {
                    picked = a;
                    it.remove();
                    break;
                }
            }
            if (picked != null) {
                TypeInsnNode hit = picked.insn;
                ctorOf.put(hit, mi);
                inited.add(hit);
                // 同一次分配的所有副本都随这次 <init> 一起"落地"
                uninit.removeIf(a -> a.insn == hit);
                continue;
            }
            // 没有自洽的：取最近的那个未初始化值，它就是被这条 <init> 消费的 objref。
            picked = uninit.pollLast();
            if (picked == null) continue;
            inited.add(picked.insn);
            TypeInsnNode origin = picked.insn;
            String target = origin.desc;
            if (target == null || target.equals(mi.owner)) continue;

            // JVM 铁律：`new T` 产生的未初始化值只能由 T.<init> 消费。所以只有两种真相：
            //   a) 分配类型是对的、owner 塌了（塌到祖先或写成无关类）→ owner := 分配类型
            //   b) 分配类型塌到祖先，且祖先链里没有任何类声明该描述符 → new := owner
            // 两者都塌（new 与 owner 同指祖先）时这里看不出真相，交给
            // widenAllocatedTypes() 按下游用点抬回。
            if (ensureCtorChain(target, mi.desc, 0)) {
                mi.owner = target;
                count++;
            } else if (mi.owner != null && isSuper(mi.owner, target)
                    && declaresCtor(mi.owner, mi.desc)) {
                origin.desc = mi.owner;
                count++;
            }
        }
        return count;
    }

    private boolean declaresCtor(String type, String desc) {
        if (type == null) return false;
        ensureKnown(type);
        Set<String> set = ctors.get(type);
        return set != null && set.contains(desc);
    }

    /** {@code ancestor} 是否在 {@code type} 的祖先链上（含自身）。 */
    private boolean isSuper(String ancestor, String type) {
        String x = type;
        for (int guard = 0; x != null && guard < 64; guard++) {
            if (x.equals(ancestor)) return true;
            if (!supers.containsKey(x) && !ensureKnown(x)) return false;
            x = supers.get(x);
        }
        return false;
    }

    private void write(File target) throws Exception {
        try (ZipOutputStream os = new ZipOutputStream(new FileOutputStream(target))) {
            for (Map.Entry<String, byte[]> e : others.entrySet()) {
                os.putNextEntry(new ZipEntry(e.getKey()));
                os.write(e.getValue());
                os.closeEntry();
            }
            for (ClassNode cn : nodes.values()) {
                byte[] data = rebuild(cn);
                if (data == null) {
                    keptClasses++;
                    ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS);
                    cn.accept(cw);
                    data = cw.toByteArray();
                } else {
                    rebuiltClasses++;
                }
                os.putNextEntry(new ZipEntry(cn.name + ".class"));
                os.write(data);
                os.closeEntry();
            }
        }
    }

    private byte[] rebuild(ClassNode cn) {
        try {
            ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_FRAMES) {
                @Override
                protected String getCommonSuperClass(String a, String b) {
                    return commonSuper(a, b);
                }
            };
            cn.accept(cw);
            byte[] out = cw.toByteArray();
            new ClassReader(out);
            return out;
        } catch (Throwable t) {
            return null;
        }
    }

    private String commonSuper(String a, String b) {
        if (a.equals(b)) return a;
        if (!ensureKnown(a) || !ensureKnown(b)) return "java/lang/Object";
        Set<String> chain = new HashSet<>();
        String x = a;
        while (x != null) {
            chain.add(x);
            x = supers.get(x);
        }
        String y = b;
        while (y != null) {
            if (chain.contains(y)) return y;
            y = supers.get(y);
        }
        return "java/lang/Object";
    }
}
