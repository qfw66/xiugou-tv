package com.fongmi.companion;

import java.io.DataInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.Deque;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 载荷 jar 的 ClassLoader。默认仍是父优先：companion 里的同名类（安卓 API 替身、
 * {@code GoProxy} / {@code MyCrypto} 这类原生库替身、几个 spider 的桌面实现）要顶替载荷里的同名类。
 *
 * <p>例外一：{@link #STAND_INS} 里的 spider 替身，在载荷里**有别的类依赖它的载荷版本**时，
 * 这个 jar 改用载荷自带的那份。依赖指二者之一：
 * <ul>
 *   <li>载荷里有类继承它（pg.jar 有 47 个网盘站继承 {@code Push}）；</li>
 *   <li>载荷 spider 包里的别的站点类引用了它的某个字段 / 方法，而桌面替身没有这个成员
 *       （pg.jar 的 {@code TGDouban} 读 {@code Douban.c}）。merge/* 等辅助包里的引用不算：
 *       那些通常是载荷版替身自己的实现细节。</li>
 * </ul>
 * 不这样做时，这些类链接到 55 行的桌面版 {@code Push}，运行时报
 * {@code Class com.github.catvod.spider.Push does not have member field ...}，
 * 网盘站的详情页全部打不开。没有依赖的 jar 行为不变，桌面替身照旧生效。
 *
 * <p>例外二：{@link #OUTDATED} 里已过时的桌面替身（Kanqiu），载荷自带就用载荷版，不看依赖。
 */
final class PayloadClassLoader extends URLClassLoader {
    static {
        registerAsParallelCapable();
    }

    static final String SPIDER_PKG = "com.github.catvod.spider.";

    /**
     * 可以让位给载荷版本的 spider 替身（简单类名）。
     *
     * <p>只放两个：{@code Push} 在桌面版里只是 55 行的直链播放壳，载荷版是网盘路由的基类；
     * {@code Douban} 只在 pg.jar 里被别的站点直接引用（实测载荷版能用）。
     * Bili / AppYsV2 / AList / Nmys 的桌面版是专门修过接口的实现，
     * 本机缓存里有几个 jar 会因「别的站点引用了载荷版成员」而让位，可能把现在能用的站点换坏，暂不放进来。
     * 宿主辅助类（HideAPI / HideUtils）和原生库替身（GoProxy / MyCrypto）必须始终用桌面版。
     */
    static final Set<String> STAND_INS = Set.of("Douban", "Push");

    /**
     * 已过时的桌面替身（简单类名 → 原因）：载荷 jar 自带同名类时一律用载荷版，不看有没有依赖。
     *
     * <p>{@code Kanqiu}：桌面版写死 {@code https://www.88kanqiu.tv} 并按 HTML 正则抓取，该域名
     * 2026-11 起只回 202 空页面，分类全空；饭太硬、pg 等载荷自带的 Kanqiu 已改用
     * {@code www.88kanqiu.pw} 和 {@code /live/<id>/source} 接口，实测分类、详情、播放线路都正常。
     * 载荷不带 Kanqiu 时（站点只写 csp_Kanqiu、没有 jar）仍是桌面版。
     */
    static final Map<String, String> OUTDATED = Map.of(
            "Kanqiu", "桌面替身已过时（写死的 88kanqiu.tv 已失效）");

    private final Set<String> payloadFirst;

    private PayloadClassLoader(URL[] urls, ClassLoader parent, Set<String> payloadFirst) {
        super(urls, parent);
        this.payloadFirst = payloadFirst;
    }

    static PayloadClassLoader create(File jar, ClassLoader parent) throws IOException {
        Map<String, String> reasons;
        try {
            reasons = scan(jar, parent);
        } catch (Throwable t) {
            // 扫描失败就退回原来的父优先，不能因为这一步让整个 jar 加载失败
            System.err.println("[PayloadClassLoader] 依赖扫描失败，按父优先加载: " + jar.getName() + " " + t);
            reasons = Collections.emptyMap();
        }
        if (!reasons.isEmpty()) {
            System.out.println("[PayloadClassLoader] " + jar.getName() + " 使用载荷自带的 " + reasons);
        }
        return new PayloadClassLoader(new URL[]{jar.toURI().toURL()}, parent,
                Collections.unmodifiableSet(new HashSet<>(reasons.keySet())));
    }

    /** 本 jar 中改为载荷优先的 spider 简单类名（测试与日志用）。 */
    Set<String> payloadFirst() {
        return payloadFirst;
    }

    @Override
    protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
        if (!isPayloadFirst(name)) return super.loadClass(name, resolve);
        synchronized (getClassLoadingLock(name)) {
            Class<?> c = findLoadedClass(name);
            if (c == null) {
                try {
                    c = findClass(name);
                } catch (ClassNotFoundException e) {
                    return super.loadClass(name, resolve);
                }
            }
            if (resolve) resolveClass(c);
            return c;
        }
    }

    private boolean isPayloadFirst(String name) {
        return !payloadFirst.isEmpty() && payloadFirst.contains(outerSimpleName(name.replace('/', '.')));
    }

    /** {@code com.github.catvod.spider.Push$1} → {@code Push}；不在 spider 包（或在子包）→ null。 */
    static String outerSimpleName(String dottedName) {
        if (!dottedName.startsWith(SPIDER_PKG)) return null;
        String simple = dottedName.substring(SPIDER_PKG.length());
        if (simple.indexOf('.') >= 0) return null;
        int inner = simple.indexOf('$');
        return inner > 0 ? simple.substring(0, inner) : simple;
    }

    /** 返回「简单类名 → 原因」，只含需要改为载荷优先的替身。 */
    static Map<String, String> scan(File jar, ClassLoader parent) throws IOException {
        Map<String, String> reasons = new LinkedHashMap<>();
        try (ZipFile zip = new ZipFile(jar)) {
            Set<String> candidates = new HashSet<>();
            for (Enumeration<? extends ZipEntry> e = zip.entries(); e.hasMoreElements(); ) {
                String n = e.nextElement().getName();
                if (!n.endsWith(".class")) continue;
                String simple = outerSimpleName(n.substring(0, n.length() - 6).replace('/', '.'));
                if (simple == null || n.indexOf('$') >= 0 || parent.getResource(n) == null) continue;
                if (OUTDATED.containsKey(simple)) {
                    reasons.put(simple, OUTDATED.get(simple));
                } else if (STAND_INS.contains(simple)) {
                    candidates.add(simple);
                }
            }
            if (candidates.isEmpty()) return reasons;

            Map<String, Integer> subclasses = new HashMap<>();
            Map<String, Set<String>> missing = new HashMap<>();
            Map<String, Set<String>> bridgeMembers = new HashMap<>();
            for (Enumeration<? extends ZipEntry> e = zip.entries(); e.hasMoreElements(); ) {
                ZipEntry entry = e.nextElement();
                String n = entry.getName();
                if (!n.endsWith(".class")) continue;
                String self = outerSimpleName(n.substring(0, n.length() - 6).replace('/', '.'));
                ClassRefs refs;
                try (InputStream in = zip.getInputStream(entry)) {
                    refs = ClassRefs.parse(in.readAllBytes());
                } catch (IOException | RuntimeException ex) {
                    continue;
                }
                // 只认 spider 包里的类（站点类及其内部类）当依赖方：merge/* 之类的混淆辅助类引用替身的成员，
                // 多半是在给载荷版替身自己干活；替身用桌面版时它们根本不会被调用，不能因此让位。
                if (refs == null || self == null) continue;
                String sup = refs.superName == null ? null : outerSimpleName(refs.superName.replace('/', '.'));
                if (sup != null && candidates.contains(sup) && !sup.equals(self)) {
                    subclasses.merge(sup, 1, Integer::sum);
                }
                for (String[] m : refs.members) {
                    String owner = outerSimpleName(m[0].replace('/', '.'));
                    if (owner == null || !candidates.contains(owner) || owner.equals(self)) continue;
                    if (m[0].indexOf('$') >= 0) continue;
                    Set<String> have = bridgeMembers.computeIfAbsent(owner, o -> bridgeMembersOf(SPIDER_PKG + o, parent));
                    if (have == null) continue;
                    String key = m[1] + ":" + m[2];
                    if (!have.contains(key)) {
                        missing.computeIfAbsent(owner, o -> new TreeSet<>()).add(m[1]);
                    }
                }
            }
            for (String c : new TreeSet<>(candidates)) {
                Integer subs = subclasses.get(c);
                Set<String> lack = missing.get(c);
                if (subs == null && lack == null) continue;
                StringBuilder why = new StringBuilder();
                if (subs != null) why.append(subs).append(" 个子类");
                if (lack != null) {
                    if (why.length() > 0) why.append("，");
                    why.append("桌面版缺成员 ").append(String.join(",", lack.stream().limit(5).toList()));
                    if (lack.size() > 5) why.append("…共 ").append(lack.size()).append(" 个");
                }
                reasons.put(c, why.toString());
            }
        }
        return reasons;
    }

    /**
     * 桌面版类可被外部引用到的成员：{@code name:descriptor}。字段 / 方法沿父类与接口向上收集，
     * 构造器只算本类声明的。拿不到（反射时缺类等）返回 null，调用方按「不确定」处理、保持父优先。
     */
    static Set<String> bridgeMembersOf(String className, ClassLoader parent) {
        try {
            Class<?> bridge = Class.forName(className, false, parent);
            Set<String> out = new HashSet<>();
            for (Constructor<?> k : bridge.getDeclaredConstructors()) {
                out.add("<init>:" + methodDescriptor(k.getParameterTypes(), void.class));
            }
            Deque<Class<?>> todo = new ArrayDeque<>();
            Set<Class<?>> seen = new HashSet<>();
            todo.add(bridge);
            while (!todo.isEmpty()) {
                Class<?> c = todo.poll();
                if (!seen.add(c)) continue;
                for (Field f : c.getDeclaredFields()) out.add(f.getName() + ":" + descriptor(f.getType()));
                for (Method m : c.getDeclaredMethods()) {
                    out.add(m.getName() + ":" + methodDescriptor(m.getParameterTypes(), m.getReturnType()));
                }
                // ArrayDeque 不收 null：Object / 接口的 getSuperclass() 是 null，不能直接 add
                if (c.getSuperclass() != null) todo.add(c.getSuperclass());
                Collections.addAll(todo, c.getInterfaces());
            }
            return out;
        } catch (Throwable t) {
            return null;
        }
    }

    static String methodDescriptor(Class<?>[] params, Class<?> ret) {
        StringBuilder sb = new StringBuilder("(");
        for (Class<?> p : params) sb.append(descriptor(p));
        return sb.append(')').append(descriptor(ret)).toString();
    }

    static String descriptor(Class<?> t) {
        if (t.isArray()) return t.getName().replace('.', '/');
        if (t == void.class) return "V";
        if (t == boolean.class) return "Z";
        if (t == byte.class) return "B";
        if (t == char.class) return "C";
        if (t == short.class) return "S";
        if (t == int.class) return "I";
        if (t == long.class) return "J";
        if (t == float.class) return "F";
        if (t == double.class) return "D";
        return "L" + t.getName().replace('.', '/') + ";";
    }

    /** 只读常量池：父类名，以及所有字段 / 方法引用（owner, name, descriptor）。 */
    static final class ClassRefs {
        String superName;
        final java.util.List<String[]> members = new java.util.ArrayList<>();

        static ClassRefs parse(byte[] data) throws IOException {
            DataInputStream in = new DataInputStream(new java.io.ByteArrayInputStream(data));
            if (in.readInt() != 0xCAFEBABE) return null;
            in.readUnsignedShort();
            in.readUnsignedShort();
            int count = in.readUnsignedShort();
            String[] utf8 = new String[count];
            int[] classIndex = new int[count];
            int[][] refs = new int[count][];
            int[][] nameAndType = new int[count][];
            for (int i = 1; i < count; i++) {
                int tag = in.readUnsignedByte();
                switch (tag) {
                    case 1 -> utf8[i] = in.readUTF();
                    case 3, 4 -> in.readInt();
                    case 5, 6 -> {
                        in.readLong();
                        i++;
                    }
                    case 7 -> classIndex[i] = in.readUnsignedShort();
                    case 8, 16, 19, 20 -> in.readUnsignedShort();
                    case 9, 10, 11 -> refs[i] = new int[]{in.readUnsignedShort(), in.readUnsignedShort()};
                    case 12 -> nameAndType[i] = new int[]{in.readUnsignedShort(), in.readUnsignedShort()};
                    case 15 -> {
                        in.readUnsignedByte();
                        in.readUnsignedShort();
                    }
                    case 17, 18 -> in.readInt();
                    default -> {
                        return null;
                    }
                }
            }
            in.readUnsignedShort();
            in.readUnsignedShort();
            int superIdx = in.readUnsignedShort();
            ClassRefs out = new ClassRefs();
            if (superIdx > 0 && superIdx < count) out.superName = utf8[classIndex[superIdx]];
            for (int i = 1; i < count; i++) {
                int[] r = refs[i];
                if (r == null) continue;
                String owner = utf8[classIndex[r[0]]];
                int[] nt = nameAndType[r[1]];
                if (owner == null || nt == null) continue;
                out.members.add(new String[]{owner, utf8[nt[0]], utf8[nt[1]]});
            }
            return out;
        }
    }
}
