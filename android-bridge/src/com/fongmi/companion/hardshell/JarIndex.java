package com.fongmi.companion.hardshell;

import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * jar 内容的只读探测工具。加固壳的形态判定、地址发现、产物验收都只依赖这里的原语，
 * 不依赖任何具体源的名字。
 */
public final class JarIndex {

    /** dex 里的 http(s) 字面量；壳把基址与路径片段分开存，所以这里只取前缀。 */
    private static final Pattern URL_LITERAL = Pattern.compile("https?://[!-~]{4,120}");

    /** 可打印 ASCII 串（dex/so 里的常量池条目）。 */
    private static final Pattern PRINTABLE = Pattern.compile("[\\x20-\\x7e]{4,200}");

    private JarIndex() {
    }

    /** jar 内是否有该条目。 */
    public static boolean has(File jar, String entry) {
        if (jar == null || !jar.isFile() || jar.length() == 0 || isEmpty(entry)) return false;
        try (ZipFile zip = new ZipFile(jar)) {
            return zip.getEntry(entry) != null;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /** 任一命中的条目名；全部未命中返回 null。 */
    public static String firstHit(File jar, String[] markers) {
        if (markers == null) return null;
        for (String m : markers) {
            if (has(jar, m)) return m;
        }
        return null;
    }

    /** 全部条目名；读不了返回空表。 */
    public static List<String> entries(File jar) {
        if (jar == null || !jar.isFile() || jar.length() == 0) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        try (ZipFile zip = new ZipFile(jar)) {
            var it = zip.entries();
            while (it.hasMoreElements()) {
                ZipEntry e = it.nextElement();
                if (!e.isDirectory()) out.add(e.getName());
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    /** 把条目解到目标文件；条目不存在或写出失败返回 false。 */
    public static boolean extract(File jar, String entry, File target) {
        if (isEmpty(entry)) return false;
        try (ZipFile zip = new ZipFile(jar)) {
            ZipEntry e = zip.getEntry(entry);
            if (e == null) return false;
            File parent = target.getParentFile();
            if (parent != null) parent.mkdirs();
            try (InputStream in = zip.getInputStream(e)) {
                Files.copy(in, target.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
            return target.isFile() && target.length() > 0;
        } catch (Throwable ignored) {
            return false;
        }
    }

    /** 读条目字节；不存在返回 null。 */
    public static byte[] read(File jar, String entry) {
        if (isEmpty(entry)) return null;
        try (ZipFile zip = new ZipFile(jar)) {
            ZipEntry e = zip.getEntry(entry);
            if (e == null) return null;
            try (InputStream in = zip.getInputStream(e)) {
                return in.readAllBytes();
            }
        } catch (Throwable ignored) {
            return null;
        }
    }

    /**
     * 汇总 jar 里所有 {@code classes*.dex} 的可打印字符串，去重保序。
     *
     * <p>dex 的字符串池本身是长度前缀的 MUTF-8，这里不解析结构，直接按可打印段切；
     * 对"找地址前缀 / 找资产名"这类用途足够，且对多 dex、加固混淆都稳。
     */
    public static List<String> dexStrings(File jar) {
        Set<String> out = new LinkedHashSet<>();
        for (String name : entries(jar)) {
            if (!name.startsWith("classes") || !name.endsWith(".dex")) continue;
            byte[] data = read(jar, name);
            if (data == null) continue;
            String text = new String(data, StandardCharsets.ISO_8859_1);
            Matcher m = PRINTABLE.matcher(text);
            while (m.find()) out.add(m.group().trim());
        }
        return new ArrayList<>(out);
    }

    /** dex 里出现的 http(s) 字面量，去重保序。 */
    public static List<String> dexUrls(File jar) {
        Set<String> out = new LinkedHashSet<>();
        for (String name : entries(jar)) {
            if (!name.startsWith("classes") || !name.endsWith(".dex")) continue;
            byte[] data = read(jar, name);
            if (data == null) continue;
            Matcher m = URL_LITERAL.matcher(new String(data, StandardCharsets.ISO_8859_1));
            while (m.find()) out.add(m.group());
        }
        return new ArrayList<>(out);
    }

    static boolean isEmpty(String s) {
        return s == null || s.trim().isEmpty();
    }
}
