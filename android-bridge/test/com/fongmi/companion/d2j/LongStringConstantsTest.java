package com.fongmi.companion.d2j;

import com.googlecode.d2j.Field;
import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.visitors.DexClassVisitor;
import com.googlecode.d2j.visitors.DexCodeVisitor;
import com.googlecode.d2j.visitors.DexMethodVisitor;

import java.io.File;
import java.io.InputStream;
import java.lang.reflect.Modifier;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Enumeration;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Standalone regression test: run with assertions enabled (-ea).
 * 用合成 dex 覆盖超长字符串常量的转换：放在最后一个寄存器、后面寄存器里有活参数、
 * 只超字符数、只超编码字节数，以及切段边界。
 */
public final class LongStringConstantsTest {
    private static final String OWNER = "Lxg/sample/LongStr;";
    private static final String HTML = buildHtml();
    private static final String ASCII = repeat("abcdefghij", 4_000);          // 40000 字符，40000 字节
    private static final String CJK = repeat("配置中心页面", 4_200);           // 25200 字符，75600 字节

    public static void main(String[] args) throws Exception {
        splitKeepsSegmentsUnderByteLimit();
        Path dir = Files.createTempDirectory("xiugou-longstr-test");
        try {
            Path dex = dir.resolve("classes.dex");
            Files.write(dex, buildDex());
            Path jar = dir.resolve("out.jar");
            PreciseDex2jar.Result result = PreciseDex2jar.convert(dex.toFile(), jar);
            assert result.classes == 1 : "classes=" + result.classes;
            assert result.longStrings == 4 : "longStrings=" + result.longStrings;
            assert !containsStubMarker(jar.toFile()) : "converted class must not contain d2j stubs";
            try (URLClassLoader cl = new URLClassLoader(new URL[]{jar.toUri().toURL()},
                    LongStringConstantsTest.class.getClassLoader())) {
                Class<?> c = Class.forName("xg.sample.LongStr", true, cl);
                longStringInLastRegister(c);
                longStringKeepsLiveRegisterAfterIt(c);
                charLimitOnly(c);
                byteLimitOnly(c);
            }
        } finally {
            deleteTree(dir.toFile());
        }
    }

    /** 与载荷 f/c.i() 同形：regs=4，超长 HTML 落在最后一个寄存器 v3。 */
    private static void longStringInLastRegister(Class<?> c) throws Exception {
        Object[] r = (Object[]) c.getMethod("page").invoke(null);
        assert Integer.valueOf(200).equals(r[0]);
        assert "text/html; charset=utf-8".equals(r[1]);
        byte[] body = ((InputStream) r[2]).readAllBytes();
        assert new String(body, StandardCharsets.UTF_8).equals(HTML) : "page body mismatch";
    }

    /** 超长串在 v1、参数在 v2：拼接不能借用 v2 当临时寄存器。 */
    private static void longStringKeepsLiveRegisterAfterIt(Class<?> c) throws Exception {
        Object r = c.getMethod("join", String.class).invoke(null, "|tail");
        assert (HTML + "|tail").equals(r) : "parameter register clobbered";
    }

    private static void charLimitOnly(Class<?> c) throws Exception {
        assert ASCII.equals(c.getMethod("ascii").invoke(null));
    }

    private static void byteLimitOnly(Class<?> c) throws Exception {
        assert CJK.equals(c.getMethod("cjk").invoke(null));
    }

    private static void splitKeepsSegmentsUnderByteLimit() {
        String s = repeat("a中\uD83D\uDE00", 30_000); // 含代理对
        List<String> parts = LongStringConstants.split(s);
        assert parts.size() > 1;
        StringBuilder joined = new StringBuilder();
        for (String p : parts) {
            assert modifiedUtf8Length(p) <= LongStringConstants.SEGMENT_BYTES : "segment too large";
            assert !Character.isHighSurrogate(p.charAt(p.length() - 1)) : "surrogate pair split";
            joined.append(p);
        }
        assert joined.toString().equals(s);
        assert LongStringConstants.split("short").size() == 1;
        assert !LongStringConstants.isTooLong("short");
        assert LongStringConstants.isTooLong(ASCII);
        assert LongStringConstants.isTooLong(CJK);
    }

    private static byte[] buildDex() {
        DexFileWriter w = new DexFileWriter();
        DexClassVisitor cv = w.visit(Modifier.PUBLIC, OWNER, "Ljava/lang/Object;", null);
        int ps = Modifier.PUBLIC | Modifier.STATIC;

        // page(): 与载荷同形的配置页响应
        DexCodeVisitor m = code(cv, ps, "page", new String[0], "[Ljava/lang/Object;", 4);
        m.visitConstStmt(Op.CONST_16, 0, 200);
        m.visitMethodStmt(Op.INVOKE_STATIC, new int[]{0},
                new Method("Ljava/lang/Integer;", "valueOf", new String[]{"I"}, "Ljava/lang/Integer;"));
        m.visitStmt1R(Op.MOVE_RESULT_OBJECT, 0);
        m.visitTypeStmt(Op.NEW_INSTANCE, 1, -1, "Ljava/io/ByteArrayInputStream;");
        m.visitFieldStmt(Op.SGET_OBJECT, 2, -1,
                new Field("Ljava/nio/charset/StandardCharsets;", "UTF_8", "Ljava/nio/charset/Charset;"));
        m.visitConstStmt(Op.CONST_STRING, 3, HTML);
        m.visitMethodStmt(Op.INVOKE_VIRTUAL, new int[]{3, 2},
                new Method("Ljava/lang/String;", "getBytes", new String[]{"Ljava/nio/charset/Charset;"}, "[B"));
        m.visitStmt1R(Op.MOVE_RESULT_OBJECT, 2);
        m.visitMethodStmt(Op.INVOKE_DIRECT, new int[]{1, 2},
                new Method("Ljava/io/ByteArrayInputStream;", "<init>", new String[]{"[B"}, "V"));
        m.visitConstStmt(Op.CONST_4, 2, 3);
        m.visitTypeStmt(Op.NEW_ARRAY, 2, 2, "[Ljava/lang/Object;");
        m.visitConstStmt(Op.CONST_4, 3, 0);
        m.visitStmt3R(Op.APUT_OBJECT, 0, 2, 3);
        m.visitConstStmt(Op.CONST_STRING, 0, "text/html; charset=utf-8");
        m.visitConstStmt(Op.CONST_4, 3, 1);
        m.visitStmt3R(Op.APUT_OBJECT, 0, 2, 3);
        m.visitConstStmt(Op.CONST_4, 0, 2);
        m.visitStmt3R(Op.APUT_OBJECT, 1, 2, 0);
        m.visitStmt1R(Op.RETURN_OBJECT, 2);
        end(m);

        // join(String): regs=3，参数在 v2，超长串在 v1
        m = code(cv, ps, "join", new String[]{"Ljava/lang/String;"}, "Ljava/lang/String;", 3);
        m.visitConstStmt(Op.CONST_STRING, 1, HTML);
        m.visitMethodStmt(Op.INVOKE_VIRTUAL, new int[]{1, 2},
                new Method("Ljava/lang/String;", "concat", new String[]{"Ljava/lang/String;"}, "Ljava/lang/String;"));
        m.visitStmt1R(Op.MOVE_RESULT_OBJECT, 0);
        m.visitStmt1R(Op.RETURN_OBJECT, 0);
        end(m);

        m = code(cv, ps, "ascii", new String[0], "Ljava/lang/String;", 1);
        m.visitConstStmt(Op.CONST_STRING, 0, ASCII);
        m.visitStmt1R(Op.RETURN_OBJECT, 0);
        end(m);

        m = code(cv, ps, "cjk", new String[0], "Ljava/lang/String;", 1);
        m.visitConstStmt(Op.CONST_STRING, 0, CJK);
        m.visitStmt1R(Op.RETURN_OBJECT, 0);
        end(m);

        cv.visitEnd();
        w.visitEnd();
        return w.toByteArray();
    }

    private static DexCodeVisitor code(DexClassVisitor cv, int access, String name, String[] params,
                                       String ret, int registers) {
        DexMethodVisitor mv = cv.visitMethod(access, new Method(OWNER, name, params, ret));
        DexCodeVisitor code = mv.visitCode();
        code.visitRegister(registers);
        return new DexCodeVisitor(code) {
            @Override
            public void visitEnd() {
                super.visitEnd();
                mv.visitEnd();
            }
        };
    }

    private static void end(DexCodeVisitor code) {
        code.visitEnd();
    }

    /** 十几万字符的页面，混合中英文，长度和编码字节数都远超单个常量上限。 */
    private static String buildHtml() {
        StringBuilder sb = new StringBuilder("<!doctype html><html><head><meta charset='utf-8'><title>网盘配置</title></head><body>");
        for (int i = 0; i < 3_000; i++) {
            sb.append("<div class='card' id='c").append(i).append("'>夸克/UC/百度 扫码登录 ").append(i).append("</div>");
        }
        return sb.append("</body></html>").toString();
    }

    private static boolean containsStubMarker(File jar) throws Exception {
        byte[] needle = "d2j: ".getBytes(StandardCharsets.US_ASCII);
        try (ZipFile zip = new ZipFile(jar)) {
            Enumeration<? extends ZipEntry> en = zip.entries();
            while (en.hasMoreElements()) {
                ZipEntry e = en.nextElement();
                if (!e.getName().endsWith(".class")) continue;
                byte[] b;
                try (InputStream in = zip.getInputStream(e)) {
                    b = in.readAllBytes();
                }
                if (indexOf(b, needle) >= 0) return true;
            }
        }
        return false;
    }

    private static int indexOf(byte[] hay, byte[] needle) {
        outer:
        for (int i = 0; i <= hay.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) continue outer;
            }
            return i;
        }
        return -1;
    }

    private static int modifiedUtf8Length(String s) {
        int n = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            n += c >= 1 && c <= 0x7F ? 1 : c <= 0x7FF ? 2 : 3;
        }
        return n;
    }

    private static String repeat(String s, int times) {
        return s.repeat(times);
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }
}
