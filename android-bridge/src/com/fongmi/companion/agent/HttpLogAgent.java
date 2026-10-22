package com.fongmi.companion.agent;

import com.github.catvod.utils.DebugLog;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;

/**
 * 调试用 Java Agent：给所有 OkHttpClient 自动装上日志拦截器。
 *
 * <p>为什么需要它：载荷里的爬虫大多直接 {@code new OkHttpClient()}（不走宿主
 * {@code com.github.catvod.net.OkHttp} 桩），只在桩里打日志只能看到一部分请求。
 * 这里在类加载期改写 {@code okhttp3.OkHttpClient$Builder.build()}，在方法入口
 * 注入一行 {@code HttpLogHook.install(this)}，于是**任何**通过 Builder 创建的
 * 客户端都会带上 {@link HttpLogHook} 的拦截器。
 *
 * <p>只有 {@code -Dxiugou.debug=true} 时才安装 transformer；关闭时开销为零。
 * 启动方式：{@code -javaagent:companion-service.jar -Dxiugou.debug=true -jar companion-service.jar}
 */
public final class HttpLogAgent {

    private HttpLogAgent() {
    }

    public static void premain(String args, Instrumentation inst) {
        if (!DebugLog.httpEnabled()) {
            return;
        }
        try {
            inst.addTransformer(new Transformer());
            System.out.println("[DBG][AGENT] OkHttp logger installed");
        } catch (Throwable t) {
            System.err.println("[DBG][AGENT] install failed: " + t);
        }
    }

    /** 动态 attach 入口（jcmd / VirtualMachine.loadAgent 时用），行为与 premain 一致。 */
    public static void agentmain(String args, Instrumentation inst) {
        premain(args, inst);
    }

    private static final class Transformer implements ClassFileTransformer {

        private static final String TARGET = "okhttp3/OkHttpClient$Builder";

        @Override
        public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
                ProtectionDomain protectionDomain, byte[] classfileBuffer) {
            if (!TARGET.equals(className)) return null;
            try {
                ClassReader reader = new ClassReader(classfileBuffer);
                ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
                reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
                    @Override
                    public MethodVisitor visitMethod(int access, String name, String descriptor,
                            String signature, String[] exceptions) {
                        MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                        if (!"build".equals(name) || !"()Lokhttp3/OkHttpClient;".equals(descriptor)) {
                            return mv;
                        }
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
                return writer.toByteArray();
            } catch (Throwable t) {
                // 改写失败就退回原字节码：宁可少日志，也不能让 OkHttp 起不来。
                System.err.println("[DBG][AGENT] transform " + className + " failed: " + t);
                return null;
            }
        }
    }
}
