package com.fongmi.companion.d2j;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.*;
import org.objectweb.asm.tree.analysis.*;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.*;
import java.util.zip.*;

/** DEX 后处理末端：恢复真实分配类型的构造调用，并按运行期类型层次生成校验帧。 */
final class JvmVerificationRepair {
    private final Map<String, ClassNode> nodes = new LinkedHashMap<>();
    private final Map<String, byte[]> entries = new LinkedHashMap<>();
    private final Map<String, ClassNode> host = new HashMap<>();
    private final Set<String> payloadFirst;
    private final ClassLoader resolver;
    private int repairedCalls;
    private int addedConstructors;

    private JvmVerificationRepair(Set<String> payloadFirst, ClassLoader resolver) {
        this.payloadFirst = Set.copyOf(payloadFirst);
        this.resolver = resolver;
    }

    static void finish(File converted, Set<String> payloadFirst, ClassLoader resolver) throws IOException {
        JvmVerificationRepair repair = new JvmVerificationRepair(payloadFirst, resolver);
        repair.read(converted);
        repair.repairConstructors();
        repair.write(converted.toPath());
        System.out.println("[DexVerification] 重建栈帧 " + repair.nodes.size()
                + " 类，恢复构造调用 " + repair.repairedCalls + " 处，按需构造转发 "
                + repair.addedConstructors + " 处");
    }

    private void read(File jar) throws IOException {
        try (ZipFile zip = new ZipFile(jar)) {
            var all = zip.entries();
            while (all.hasMoreElements()) {
                ZipEntry entry = all.nextElement();
                byte[] data;
                try (InputStream in = zip.getInputStream(entry)) { data = in.readAllBytes(); }
                if (entries.put(entry.getName(), data) != null)
                    throw new IOException("Duplicate converted entry: " + entry.getName());
                if (entry.getName().endsWith(".class")) {
                    ClassNode node = new ClassNode();
                    new ClassReader(data).accept(node, ClassReader.SKIP_FRAMES);
                    nodes.put(node.name, node);
                }
            }
        }
    }

    /** SourceInterpreter 的复制操作保留原始 NEW；不以指令邻接关系猜测构造接收者。 */
    private void repairConstructors() throws IOException {
        for (ClassNode node : nodes.values()) {
            for (MethodNode method : new ArrayList<>(node.methods)) {
                if ((method.access & (Opcodes.ACC_ABSTRACT | Opcodes.ACC_NATIVE)) != 0) continue;
                AbstractInsnNode self = new VarInsnNode(Opcodes.ALOAD, 0);
                SourceInterpreter interpreter = new SourceInterpreter(Opcodes.ASM9) {
                    @Override public SourceValue copyOperation(AbstractInsnNode insn, SourceValue value) {
                        return value;
                    }
                    @Override public SourceValue newParameterValue(boolean instance, int local, Type type) {
                        return instance && local == 0 ? new SourceValue(1, self)
                                : super.newParameterValue(instance, local, type);
                    }
                };
                Frame<SourceValue>[] frames;
                try { frames = new Analyzer<>(interpreter).analyze(node.name, method); }
                catch (AnalyzerException e) { throw new IOException("Cannot analyze " + node.name + "." + method.name + method.desc, e); }
                AbstractInsnNode[] code = method.instructions.toArray();
                for (int i = 0; i < code.length; i++) {
                    if (!(code[i] instanceof MethodInsnNode call) || call.getOpcode() != Opcodes.INVOKESPECIAL
                            || !call.name.equals("<init>") || frames[i] == null) continue;
                    int slot = frames[i].getStackSize() - Type.getArgumentTypes(call.desc).length - 1;
                    if (slot < 0) throw new IOException("Missing constructor receiver: " + node.name);
                    SourceValue receiver = frames[i].getStack(slot);
                    if (receiver.insns.size() != 1) continue;
                    AbstractInsnNode origin = receiver.insns.iterator().next();
                    String target = null;
                    if (origin instanceof TypeInsnNode allocation && origin.getOpcode() == Opcodes.NEW) {
                        if (!allocation.desc.equals(call.owner)) target = allocation.desc;
                    } else if (origin == self && method.name.equals("<init>")
                            && !call.owner.equals(node.name) && !call.owner.equals(node.superName)) {
                        target = node.superName;
                    }
                    if (target == null) continue;
                    if (!isAssignable(call.owner, target))
                        throw new IOException("Unproven constructor owner: " + target + " -> " + call.owner + call.desc);
                    ensureConstructor(target, call.desc, new HashSet<>());
                    call.owner = target;
                    repairedCalls++;
                }
            }
        }
    }

    private void ensureConstructor(String type, String descriptor, Set<String> active) throws IOException {
        if (!active.add(type)) throw new IOException("Cyclic constructor hierarchy: " + type);
        ClassNode node = hierarchy(type);
        for (MethodNode method : node.methods)
            if (method.name.equals("<init>") && method.desc.equals(descriptor)) return;
        if (node != nodes.get(type) || node.superName == null || (node.access & Opcodes.ACC_INTERFACE) != 0)
            throw new IOException("Missing parent constructor: " + type + descriptor);
        ensureConstructor(node.superName, descriptor, active);
        ClassNode parent = hierarchy(node.superName);
        MethodNode parentCtor = parent.methods.stream().filter(m -> m.name.equals("<init>") && m.desc.equals(descriptor))
                .findFirst().orElseThrow();
        if ((parentCtor.access & Opcodes.ACC_PRIVATE) != 0)
            throw new IOException("Inaccessible parent constructor: " + node.superName + descriptor);
        MethodNode ctor = new MethodNode(Opcodes.ACC_PUBLIC, "<init>", descriptor, null, null);
        ctor.instructions.add(new VarInsnNode(Opcodes.ALOAD, 0));
        int local = 1;
        for (Type parameter : Type.getArgumentTypes(descriptor)) {
            ctor.instructions.add(new VarInsnNode(parameter.getOpcode(Opcodes.ILOAD), local));
            local += parameter.getSize();
        }
        ctor.instructions.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, node.superName, "<init>", descriptor, false));
        ctor.instructions.add(new InsnNode(Opcodes.RETURN));
        ctor.maxLocals = local;
        ctor.maxStack = local;
        node.methods.add(ctor);
        addedConstructors++;
    }

    private void write(Path destination) throws IOException {
        Path pending = destination.resolveSibling(destination.getFileName() + ".verify.tmp");
        try {
            try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(pending))) {
                for (var entry : entries.entrySet()) {
                    byte[] data = entry.getValue();
                    if (entry.getKey().endsWith(".class")) {
                        ClassNode node = nodes.get(entry.getKey().substring(0, entry.getKey().length() - 6));
                        ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_FRAMES) {
                            @Override protected String getCommonSuperClass(String a, String b) {
                                try { return commonSuper(a, b); }
                                catch (IOException e) { throw new IllegalStateException("Cannot resolve frame types " + a + ", " + b, e); }
                            }
                        };
                        try { node.accept(writer); data = writer.toByteArray(); }
                        catch (RuntimeException e) { throw new IOException("Cannot rebuild frames: " + node.name + ": " + e.getMessage(), e); }
                    }
                    out.putNextEntry(new ZipEntry(entry.getKey()));
                    out.write(data);
                    out.closeEntry();
                }
            }
            Files.move(pending, destination, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(pending); }
    }

    /** 父加载器资源只读解析，不装载或初始化载荷；例外集由真实 PayloadClassLoader 提供。 */
    private ClassNode hierarchy(String name) throws IOException {
        ClassNode own = nodes.get(name);
        if (own != null && isPayloadFirst(name)) return own;
        if (!host.containsKey(name)) {
            try (InputStream in = resolver.getResourceAsStream(name + ".class")) {
                if (in == null) host.put(name, null);
                else {
                    ClassNode node = new ClassNode();
                    new ClassReader(in).accept(node, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                    host.put(name, node);
                }
            }
        }
        ClassNode node = host.get(name);
        if (node != null) return node;
        if (own != null) return own;
        throw new IOException("Missing frame hierarchy: " + name);
    }

    /** 键与 PayloadClassLoader.scan 一致：spider 替身是简单类名，bean / net / utils 辅助类是点分全名；内部类随外层类。 */
    private boolean isPayloadFirst(String name) {
        int nested = name.indexOf('$');
        String outer = nested < 0 ? name : name.substring(0, nested);
        if (payloadFirst.contains(outer.replace('/', '.'))) return true;
        String prefix = "com/github/catvod/spider/";
        if (!outer.startsWith(prefix)) return false;
        String simple = outer.substring(prefix.length());
        return !simple.contains("/") && payloadFirst.contains(simple);
    }

    private boolean isAssignable(String target, String source) throws IOException {
        if (target.equals(source) || target.equals("java/lang/Object")) return true;
        if (source.startsWith("[")) {
            if (target.equals("java/lang/Cloneable") || target.equals("java/io/Serializable")) return true;
            if (!target.startsWith("[")) return false;
            String a = component(target), b = component(source);
            return reference(a) && reference(b) ? isAssignable(a, b) : a.equals(b);
        }
        if (target.startsWith("[")) return false;
        Set<String> seen = new HashSet<>();
        Deque<String> pending = new ArrayDeque<>();
        pending.add(source);
        while (!pending.isEmpty()) {
            String type = pending.removeFirst();
            if (target.equals(type)) return true;
            if (!seen.add(type)) continue;
            ClassNode node = hierarchy(type);
            if (node.superName != null) pending.addLast(node.superName);
            pending.addAll(node.interfaces);
        }
        return false;
    }

    private String commonSuper(String a, String b) throws IOException {
        // StackMapTable 的合并类型可以安全退到 Object：这里的两个引用类型
        // 可能来自载荷自带但未随 companion 打包的可选库（例如 Sardine 的
        // DavResource）。构造器重写仍走 isAssignable 的严格路径，不在此处放宽。
        try {
            if (isAssignable(a, b)) return a;
            if (isAssignable(b, a)) return b;
        } catch (IOException missingType) {
            return "java/lang/Object";
        }
        if (a.startsWith("[") && b.startsWith("[")) {
            String ac = component(a), bc = component(b);
            if (reference(ac) && reference(bc)) return arrayOf(commonSuper(ac, bc));
            return "java/lang/Object";
        }
        if (a.startsWith("[") || b.startsWith("[")) return "java/lang/Object";
        ClassNode left;
        ClassNode right;
        try {
            left = hierarchy(a);
            right = hierarchy(b);
        } catch (IOException missingType) {
            return "java/lang/Object";
        }
        if ((left.access & Opcodes.ACC_INTERFACE) != 0 || (right.access & Opcodes.ACC_INTERFACE) != 0)
            return "java/lang/Object";
        String type = left.superName;
        Set<String> seen = new HashSet<>();
        while (type != null && seen.add(type)) {
            try {
                if (isAssignable(type, b)) return type;
                type = hierarchy(type).superName;
            } catch (IOException missingType) {
                return "java/lang/Object";
            }
        }
        throw new IOException("No common frame superclass: " + a + ", " + b);
    }

    private static boolean reference(String type) { return type.length() > 1; }
    private static String component(String array) {
        String element = array.substring(1);
        return element.startsWith("L") ? element.substring(1, element.length() - 1) : element;
    }
    private static String arrayOf(String component) {
        return component.startsWith("[") ? "[" + component : "[L" + component + ";";
    }
}

