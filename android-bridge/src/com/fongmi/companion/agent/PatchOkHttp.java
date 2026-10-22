package com.fongmi.companion.agent;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * 构建期补丁：给 fat jar 里的 {@code okhttp3/OkHttpClient$Builder.class} 注入一行
 * {@code HttpLogHook.install(this)}。
 *
 * <p>为什么不在运行期用 javaagent：发布包自带的是 jlink 裁剪 JRE，没有
 * {@code java.instrument} 模块，{@code -javaagent} 直接起不来。构建期改写一次，
 * 运行期只多一次「调试开关为 false 就 return」的空调用，代价可以忽略。
 *
 * <p>用法：{@code java -cp <classes+libs> com.fongmi.companion.agent.PatchOkHttp <Builder.class>}
 */
public final class PatchOkHttp {

    private PatchOkHttp() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: PatchOkHttp <path/to/okhttp3/OkHttpClient$Builder.class>");
            System.exit(2);
            return;
        }
        Path file = Paths.get(args[0]);
        if (!Files.isRegularFile(file)) {
            System.err.println("[PatchOkHttp] not found: " + file);
            System.exit(3);
            return;
        }
        byte[] original = Files.readAllBytes(file);
        ClassReader reader = new ClassReader(original);
        ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
        final boolean[] patched = {false};
        reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                    String signature, String[] exceptions) {
                MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                if (!"build".equals(name) || !"()Lokhttp3/OkHttpClient;".equals(descriptor)) {
                    return mv;
                }
                patched[0] = true;
                return new MethodVisitor(Opcodes.ASM9, mv) {
                    @Override
                    public void visitCode() {
                        super.visitCode();
                        mv.visitVarInsn(Opcodes.ALOAD, 0);
                        mv.visitMethodInsn(Opcodes.INVOKESTATIC,
                                "com/fongmi/companion/agent/HttpLogHook", "install",
                                "(Lokhttp3/OkHttpClient$Builder;)V", false);
                    }
                };
            }
        }, 0);
        if (!patched[0]) {
            System.err.println("[PatchOkHttp] build() not found in " + file);
            System.exit(4);
            return;
        }
        Files.write(file, writer.toByteArray());
        System.out.println("[PatchOkHttp] patched " + file);
    }
}
