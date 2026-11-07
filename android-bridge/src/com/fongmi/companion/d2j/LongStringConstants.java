package com.fongmi.companion.d2j;

import com.googlecode.d2j.node.DexClassNode;
import com.googlecode.d2j.node.DexFileNode;
import com.googlecode.d2j.node.DexMethodNode;
import com.googlecode.d2j.node.insn.ConstStmtNode;
import com.googlecode.d2j.node.insn.DexStmtNode;
import com.googlecode.d2j.reader.Op;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.ListIterator;
import java.util.Map;

/**
 * 超长字符串常量的转换。
 *
 * <p>class 常量池单个字符串上限 65535 字节（modified UTF-8）。dex2jar 自带的
 * {@code DexFix.fixTooLongStringConstant} 在 dex 层把超长 const-string 改写成 StringBuilder 拼接，
 * 但拼接借用了「目标寄存器 + 1」当临时寄存器，且没有真正扩充寄存器数：目标是最后一个寄存器时
 * 临时寄存器越界，整个方法被降级成抛 VerifyError 的桩；不是最后一个时又会踩坏后面的活寄存器。
 *
 * <p>这里改成：转换前把超长 const-string 换成短占位串（DexFix 看不到超长串，不再改写），
 * 生成字节码时再把占位串的 ldc 就地展开成按字节上限切段的 StringBuilder 拼接。
 * 展开只用操作数栈、不占寄存器 / 局部变量，也不引入新的跳转。
 */
final class LongStringConstants {

    /** 超过任一阈值就接管：DexFix 按字符数 >= Short.MAX_VALUE 改写；常量池按编码字节数限制。 */
    private static final int DEXFIX_CHAR_LIMIT = Short.MAX_VALUE;
    /** 单段编码字节上限，留出余量。 */
    static final int SEGMENT_BYTES = 65000;
    /** 占位串前缀：含 NUL 与私用区字符，真实代码里不会出现。 */
    private static final String PLACEHOLDER = "\u0000xg-long-str\uE000#";

    private final Map<String, String> originals = new HashMap<>();

    /** 替换 fileNode 里所有超长 const-string，返回替换处数。 */
    int stash(DexFileNode fileNode) {
        if (fileNode.clzs == null) return 0;
        int count = 0;
        for (DexClassNode clz : fileNode.clzs) {
            if (clz.methods == null) continue;
            for (DexMethodNode m : clz.methods) {
                if (m.codeNode == null || m.codeNode.stmts == null) continue;
                ListIterator<DexStmtNode> it = m.codeNode.stmts.listIterator();
                while (it.hasNext()) {
                    DexStmtNode insn = it.next();
                    if (!(insn instanceof ConstStmtNode)) continue;
                    if (insn.op != Op.CONST_STRING && insn.op != Op.CONST_STRING_JUMBO) continue;
                    ConstStmtNode cst = (ConstStmtNode) insn;
                    if (!(cst.value instanceof String) || !isTooLong((String) cst.value)) continue;
                    String key = PLACEHOLDER + originals.size();
                    originals.put(key, (String) cst.value);
                    it.set(new ConstStmtNode(insn.op, cst.a, key));
                    count++;
                }
            }
        }
        return count;
    }

    /** 包一层 MethodVisitor：遇到占位串的 ldc 就展开成原串。无占位串时原样返回。 */
    MethodVisitor restore(MethodVisitor mv) {
        if (originals.isEmpty()) return mv;
        return new MethodVisitor(Opcodes.ASM9, mv) {
            @Override
            public void visitLdcInsn(Object value) {
                String original = value instanceof String ? originals.get(value) : null;
                if (original == null) {
                    super.visitLdcInsn(value);
                } else {
                    emit(this, original);
                }
            }
        };
    }

    static boolean isTooLong(String s) {
        return s.length() >= DEXFIX_CHAR_LIMIT || utf8Length(s, SEGMENT_BYTES + 1) > SEGMENT_BYTES;
    }

    /** 生成「把 s 压栈」的指令：放得下就一条 ldc，否则 new StringBuilder 逐段 append。 */
    static void emit(MethodVisitor mv, String s) {
        List<String> parts = split(s);
        if (parts.size() == 1) {
            mv.visitLdcInsn(s);
            return;
        }
        mv.visitTypeInsn(Opcodes.NEW, "java/lang/StringBuilder");
        mv.visitInsn(Opcodes.DUP);
        mv.visitLdcInsn(s.length());
        mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/StringBuilder", "<init>", "(I)V", false);
        for (String part : parts) {
            mv.visitLdcInsn(part);
            mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "append",
                    "(Ljava/lang/String;)Ljava/lang/StringBuilder;", false);
        }
        mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "toString",
                "()Ljava/lang/String;", false);
    }

    /** 按 modified UTF-8 字节数切段，每段不超过 SEGMENT_BYTES；不拆开代理对。 */
    static List<String> split(String s) {
        List<String> parts = new ArrayList<>();
        int start = 0;
        int bytes = 0;
        for (int i = 0; i < s.length(); i++) {
            int n = charBytes(s.charAt(i));
            boolean pair = Character.isHighSurrogate(s.charAt(i)) && i + 1 < s.length()
                    && Character.isLowSurrogate(s.charAt(i + 1));
            int need = pair ? n + charBytes(s.charAt(i + 1)) : n;
            if (bytes + need > SEGMENT_BYTES && i > start) {
                parts.add(s.substring(start, i));
                start = i;
                bytes = 0;
            }
            bytes += need;
            if (pair) i++;
        }
        parts.add(s.substring(start));
        return parts;
    }

    /** modified UTF-8 编码长度，超过 cap 提前返回。 */
    private static int utf8Length(String s, int cap) {
        int bytes = 0;
        for (int i = 0; i < s.length() && bytes <= cap; i++) {
            bytes += charBytes(s.charAt(i));
        }
        return bytes;
    }

    private static int charBytes(char c) {
        if (c >= 0x0001 && c <= 0x007F) return 1;
        if (c <= 0x07FF) return 2; // 含 U+0000
        return 3;
    }
}
