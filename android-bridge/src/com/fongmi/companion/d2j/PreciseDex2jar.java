package com.fongmi.companion.d2j;

import com.googlecode.d2j.converter.IR2JConverter;
import com.googlecode.d2j.dex.ClassVisitorFactory;
import com.googlecode.d2j.dex.Dex2Asm;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.dex.DexExceptionHandler;
import com.googlecode.d2j.dex.ExDex2Asm;
import com.googlecode.d2j.dex.LambadaNameSafeClassAdapter;
import com.googlecode.d2j.node.DexFileNode;
import com.googlecode.d2j.reader.BaseDexFileReader;
import com.googlecode.d2j.reader.DexFileReader;
import com.googlecode.dex2jar.ir.IrMethod;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.io.File;
import java.io.IOException;
import java.net.URI;
import java.nio.file.FileSystem;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * 等价于 {@code Dex2jar.from(in).to(out)} 的默认配置（跳过调试信息、只算 maxs、不优化 synchronized），
 * 唯一差别是 IR 优化管线里的 {@code NewTransformer} 换成 {@link PreciseNewTransformer}。
 *
 * <p>dex2jar 的优化管线写死在 {@code Dex2jar.doTranslate} 内部的匿名 {@code ExDex2Asm} 里，
 * {@code T_NEW} 又是 {@code static final}，无法注入，只能在这里复刻驱动流程。
 * 升级 dex2jar 版本时需要对照上游 {@code Dex2jar.doTranslate} 与 {@code optimize} 重新核对。
 */
public final class PreciseDex2jar {

    /** dex2jar 默认读取配置：SKIP_DEBUG | IGNORE_READ_EXCEPTION（与 Dex2jar.doTranslate 一致）。 */
    private static final int READER_CONFIG = DexFileReader.SKIP_DEBUG | DexFileReader.IGNORE_READ_EXCEPTION;

    private PreciseDex2jar() {
    }

    /** 转换结果统计。 */
    public static final class Result {
        public final int classes;
        public final int keptMismatchedNew;

        Result(int classes, int keptMismatchedNew) {
            this.classes = classes;
            this.keptMismatchedNew = keptMismatchedNew;
        }
    }

    public static Result convert(File dexOrApk, Path outJar) throws IOException {
        PreciseNewTransformer newTransformer = new PreciseNewTransformer();
        Dex2jar source = Dex2jar.from(dexOrApk);
        BaseDexFileReader reader = source.getReader();
        DexExceptionHandler handler = source.getExceptionHandler();

        DexFileNode fileNode = new DexFileNode();
        reader.accept(fileNode, READER_CONFIG);

        Files.deleteIfExists(outJar);
        Path parent = outJar.toAbsolutePath().getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        Map<String, String> env = new HashMap<>();
        env.put("create", "true");
        URI uri = URI.create("jar:" + outJar.toAbsolutePath().toUri());
        int[] classCount = {0};
        try (FileSystem zip = FileSystems.newFileSystem(uri, env)) {
            Path root = zip.getPath("/");
            ClassVisitorFactory cvf = name -> {
                ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS);
                LambadaNameSafeClassAdapter rca = new LambadaNameSafeClassAdapter(cw, false);
                return new ClassVisitor(Opcodes.ASM9, rca) {
                    @Override
                    public void visitEnd() {
                        super.visitEnd();
                        String className = rca.getClassName();
                        byte[] data;
                        try {
                            data = cw.toByteArray();
                        } catch (Exception ex) {
                            System.err.println("[PreciseDex2jar] ASM 生成 class 失败: " + className);
                            if (handler != null) {
                                handler.handleFileException(ex);
                            }
                            return;
                        }
                        try {
                            Path file = root.resolve(className + ".class");
                            Path dir = file.getParent();
                            if (dir != null) {
                                Files.createDirectories(dir);
                            }
                            Files.write(file, data);
                            classCount[0]++;
                        } catch (IOException e) {
                            e.printStackTrace(System.err);
                        }
                    }
                };
            };
            new ExDex2Asm(handler) {
                @Override
                public void optimize(IrMethod irMethod) {
                    T_CLEAN_LABEL.transform(irMethod);
                    T_DEAD_CODE.transform(irMethod);
                    T_REMOVE_LOCAL.transform(irMethod);
                    T_REMOVE_CONST.transform(irMethod);
                    T_ZERO.transform(irMethod);
                    if (T_NPE.transformReportChanged(irMethod)) {
                        T_DEAD_CODE.transform(irMethod);
                        T_REMOVE_LOCAL.transform(irMethod);
                        T_REMOVE_CONST.transform(irMethod);
                    }
                    newTransformer.transform(irMethod);
                    T_FILL_ARRAY.transform(irMethod);
                    T_AGG.transform(irMethod);
                    T_MULTI_ARRAY.transform(irMethod);
                    T_VOID_INVOKE.transform(irMethod);
                    T_DEAD_CODE.transform(irMethod);
                    T_REMOVE_LOCAL.transform(irMethod);
                    T_REMOVE_CONST.transform(irMethod);
                    T_TYPE.transform(irMethod);
                    T_UNSSA.transform(irMethod);
                    T_IR_2_J_REG_ASSIGN.transform(irMethod);
                    T_TRIM_EX.transform(irMethod);
                }

                @Override
                public void ir2j(IrMethod irMethod, MethodVisitor mv, Dex2Asm.ClzCtx clzCtx) {
                    new IR2JConverter()
                            .optimizeSynchronized(false).clzCtx(clzCtx).ir(irMethod).asm(mv).convert();
                }
            }.convertDex(fileNode, cvf);
        }
        return new Result(classCount[0], newTransformer.keptMismatched.get());
    }
}
