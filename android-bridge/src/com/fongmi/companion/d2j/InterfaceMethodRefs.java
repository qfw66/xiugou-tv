package com.fongmi.companion.d2j;

import com.googlecode.d2j.node.DexClassNode;
import com.googlecode.d2j.node.DexFileNode;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 把指向接口的方法引用从 Methodref 改成 InterfaceMethodref。
 *
 * <p>dex2jar 只有同时看到 owner 的 class 定义时才知道 owner 是不是接口；owner 不在本次 dex 里
 * （JDK 的 {@code Comparator} / {@code List} / {@code Map}，或宿主提供的 {@code android.*} 桩）
 * 时一律按 class 发射 Methodref。JVM 解析常量池时要求接口方法必须是 InterfaceMethodref，否则抛
 * {@code IncompatibleClassChangeError: Method 'java.util.Comparator java.util.Comparator.comparing(
 * java.util.function.Function)' must be InterfaceMethodref constant}，调用它的整个方法直接失败。
 * 实测 tvbox-1102 的 fm.jar：{@code Demo.categoryContent} 用了
 * {@code Comparator.comparing(...).thenComparing(...).reversed()}，桌面端整站不可用。
 *
 * <p>owner 是不是接口，按下面的顺序判定：
 * <ol>
 *   <li>本次要转换的 dex 里声明为接口的类 —— 载荷自己的接口只能靠这个；</li>
 *   <li>宿主 classpath 上能否加载到 —— JDK 接口与我们提供的 {@code android.*} 桩，等于运行期真相；</li>
 *   <li>都判不出就保留 dex2jar 的原结论，不猜。</li>
 * </ol>
 *
 * <p>只改引用的 tag，不改方法体：转换后每个 class 的代码数组长度、跳转偏移、栈帧都原样保留。
 */
final class InterfaceMethodRefs {

    /** owner → 是否接口；查不到的记在 {@link #unknown} 里，避免反复 ClassNotFoundException。 */
    private final Map<String, Boolean> kinds = new HashMap<>();
    private final Set<String> unknown = new HashSet<>();
    private final ClassLoader resolver;
    private int patched;

    private InterfaceMethodRefs(Set<String> interfaces, ClassLoader resolver) {
        this.resolver = resolver;
        for (String name : interfaces) {
            kinds.put(name, Boolean.TRUE);
        }
    }

    /** 收集本次 dex 里所有接口的名字（内部名），并记住宿主 classloader。 */
    static InterfaceMethodRefs of(DexFileNode fileNode, ClassLoader resolver) {
        Set<String> interfaces = new HashSet<>();
        List<DexClassNode> classes = fileNode.clzs;
        if (classes != null) {
            for (DexClassNode clz : classes) {
                if ((clz.access & Opcodes.ACC_INTERFACE) == 0) continue;
                String name = internalName(clz.className);
                if (name != null) interfaces.add(name);
            }
        }
        return new InterfaceMethodRefs(interfaces, resolver);
    }

    /** 修正处数（只统计真正改了 tag 的指令）。 */
    int patched() {
        return patched;
    }

    /**
     * 修正一个 class。ASM 解析或生成失败时原样返回输入，绝不让转换因为这个后处理整体失败。
     */
    byte[] fix(byte[] classBytes) {
        int[] hits = {0};
        try {
            ClassReader reader = new ClassReader(classBytes);
            ClassWriter writer = new ClassWriter(0);
            reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
                @Override
                public MethodVisitor visitMethod(int access, String name, String descriptor,
                                                 String signature, String[] exceptions) {
                    MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                    if (mv == null) return null;
                    return new MethodVisitor(Opcodes.ASM9, mv) {
                        @Override
                        public void visitMethodInsn(int opcode, String owner, String name, String descriptor,
                                                    boolean isInterface) {
                            boolean want = wantInterface(opcode, owner, isInterface);
                            if (want != isInterface) hits[0]++;
                            super.visitMethodInsn(opcode, owner, name, descriptor, want);
                        }
                    };
                }
            }, 0);
            if (hits[0] == 0) return classBytes;
            byte[] fixed = writer.toByteArray();
            patched += hits[0];
            return fixed;
        } catch (Throwable t) {
            System.err.println("[InterfaceMethodRefs] 跳过（后处理失败）: " + t);
            return classBytes;
        }
    }

    /** invokeinterface 的常量只能是 InterfaceMethodref；其余交给 {@link #kindOf}。 */
    private boolean wantInterface(int opcode, String owner, boolean current) {
        if (opcode == Opcodes.INVOKEINTERFACE) return true;
        Boolean kind = kindOf(owner);
        return kind != null ? kind : current;
    }

    /** true/false = 已知；null = 判不出，调用方保留原样。 */
    private Boolean kindOf(String owner) {
        if (owner == null || owner.isEmpty()) return null;
        Boolean known = kinds.get(owner);
        if (known != null) return known;
        if (unknown.contains(owner)) return null;
        Boolean kind = null;
        try {
            kind = Class.forName(owner.replace('/', '.'), false, resolver).isInterface();
        } catch (Throwable ignored) {
            kind = null;
        }
        if (kind == null) {
            unknown.add(owner);
        } else {
            kinds.put(owner, kind);
        }
        return kind;
    }

    /** dex 里的类名是 {@code Lpkg/Name;} 形式，class 文件里用 {@code pkg/Name}。 */
    private static String internalName(String dexName) {
        if (dexName == null || dexName.isEmpty()) return null;
        if (dexName.charAt(0) == 'L' && dexName.endsWith(";")) {
            return dexName.substring(1, dexName.length() - 1);
        }
        return dexName;
    }
}
