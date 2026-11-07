package com.fongmi.companion;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.jar.JarEntry;
import java.util.jar.JarOutputStream;
import java.util.stream.Stream;
import javax.tools.JavaCompiler;
import javax.tools.ToolProvider;

/**
 * 载荷 jar 里自带 Push / Douban，且有别的载荷类依赖它们时，这两个类必须用载荷版本；
 * 没有依赖的替身（AList）和原生库替身（GoProxy）仍用桌面版。
 *
 * <p>pg.jar 的真实情况：47 个网盘站继承载荷的 Push，TGDouban 读 {@code Douban.c}；
 * 父优先时它们链接到桌面版，报 {@code does not have member field}。
 *
 * <p>另一类是已过时的桌面替身（Kanqiu）：载荷自带就用载荷版，不看依赖。
 *
 * <p>运行（需要 JDK，要现场编译夹具）：
 * {@code java -ea -cp <test classes>;<companion-service.jar>;companion\lib\* com.fongmi.companion.PayloadClassLoaderTest}
 */
public final class PayloadClassLoaderTest {

    public static void main(String[] args) throws Exception {
        Path work = Files.createTempDirectory("payload-cl-test");
        try {
            File jar = buildJar(work, "payload", Map.of(
                    "Push", "import com.github.catvod.crawler.Spider;\n"
                            + "public class Push extends Spider {\n"
                            + "  public static String payloadMarker() { return \"payload-push\"; }\n"
                            + "  public Runnable task() { return new Runnable() { public void run() {} }; }\n"
                            + "}\n",
                    "PanSite", "public class PanSite extends Push {\n"
                            + "  public String homeContent(boolean filter) { return payloadMarker(); }\n"
                            + "}\n",
                    "Douban", "import com.github.catvod.crawler.Spider;\n"
                            + "public class Douban extends Spider {\n"
                            + "  public static final java.util.regex.Pattern c = java.util.regex.Pattern.compile(\"payload-douban\");\n"
                            + "}\n",
                    "TGDouban", "import com.github.catvod.crawler.Spider;\n"
                            + "public class TGDouban extends Spider {\n"
                            + "  public String homeContent(boolean filter) { return Douban.c.pattern(); }\n"
                            + "}\n",
                    "AList", "import com.github.catvod.crawler.Spider;\n"
                            + "public class AList extends Spider {\n"
                            + "  public static Object payloadOnlyImpl = new Object();\n"
                            + "  public String homeContent(boolean filter) { return \"payload-alist\"; }\n"
                            + "}\n",
                    "UseAList", "import com.github.catvod.crawler.Spider;\n"
                            + "public class UseAList extends Spider {\n"
                            + "  public String homeContent(boolean filter) throws Exception {\n"
                            + "    AList a = new AList();\n"
                            + "    return a.homeContent(false) + a.searchContent(\"k\", false);\n"
                            + "  }\n"
                            + "}\n",
                    "GoProxy", "public class GoProxy {\n"
                            + "  public static void payloadOnly() {}\n"
                            + "}\n",
                    "UseGo", "public class UseGo {\n"
                            + "  public static void go() { GoProxy.payloadOnly(); }\n"
                            + "}\n",
                    // AList 不在可让位名单里：即便有站点类引用它的载荷专有成员，也始终用桌面版
                    "UseAListField", "public class UseAListField {\n"
                            + "  public static Object get() { return AList.payloadOnlyImpl; }\n"
                            + "}\n"));
            ClassLoader parent = PayloadClassLoaderTest.class.getClassLoader();

            plainParentFirstBreaksPayloadSubclasses(jar, parent);
            dependentStandInsComeFromPayload(jar, parent);
            noDependentsKeepsDesktopVersion(work, parent);
            outdatedStandInAlwaysComesFromPayload(work, parent);
            System.out.println("PayloadClassLoaderTest OK");
        } finally {
            deleteTree(work);
        }
    }

    /** 回归基线：改动前的普通父优先 URLClassLoader 下，TGDouban 读不到 Douban.c。 */
    private static void plainParentFirstBreaksPayloadSubclasses(File jar, ClassLoader parent) throws Exception {
        try (URLClassLoader plain = new URLClassLoader(new URL[]{jar.toURI().toURL()}, parent)) {
            Throwable error = null;
            try {
                callHomeContent(plain, "TGDouban");
            } catch (InvocationTargetException e) {
                error = e.getCause();
            }
            assert error instanceof NoSuchFieldError : "plain parent-first loader should hit NoSuchFieldError, got " + error;
        }
    }

    private static void dependentStandInsComeFromPayload(File jar, ClassLoader parent) throws Exception {
        try (PayloadClassLoader loader = PayloadClassLoader.create(jar, parent)) {
            assert loader.payloadFirst().equals(java.util.Set.of("Push", "Douban"))
                    : "only Push (subclassed) and Douban (missing member) flip, got " + loader.payloadFirst();

            Class<?> pan = loader.loadClass("com.github.catvod.spider.PanSite");
            assert pan.getSuperclass().getClassLoader() == loader : "PanSite must extend the payload Push";
            assert "payload-push".equals(callHomeContent(loader, "PanSite"));
            assert "payload-douban".equals(callHomeContent(loader, "TGDouban")) : "TGDouban must see payload Douban.c";

            Class<?> inner = Class.forName("com.github.catvod.spider.Push$1", false, loader);
            assert inner.getClassLoader() == loader : "inner classes follow their outer class";

            Class<?> alist = loader.loadClass("com.github.catvod.spider.AList");
            assert alist.getClassLoader() != loader : "AList has no dependents needing the payload copy: desktop version wins";
            Class<?> go = loader.loadClass("com.github.catvod.spider.GoProxy");
            assert go.getClassLoader() != loader : "GoProxy is a native-library stand-in and must never flip";
            Class<?> okhttp = loader.loadClass("com.github.catvod.crawler.Spider");
            assert okhttp.getClassLoader() != loader : "non-spider classes stay parent-first";
        }
    }

    private static void noDependentsKeepsDesktopVersion(Path work, ClassLoader parent) throws Exception {
        File jar = buildJar(work, "plain", Map.of(
                "Push", "import com.github.catvod.crawler.Spider;\n"
                        + "public class Push extends Spider {\n"
                        + "  public static Object impl = new Object();\n"
                        + "}\n",
                "Other", "import com.github.catvod.crawler.Spider;\n"
                        + "public class Other extends Spider {}\n",
                // 混淆辅助包里的类引用载荷 Push 的成员：那是载荷版 Push 自己的实现细节，不算依赖方
                "com.github.catvod.helper.PushImpl", "public class PushImpl {\n"
                        + "  public static Object get() { return com.github.catvod.spider.Push.impl; }\n"
                        + "}\n"));
        try (PayloadClassLoader loader = PayloadClassLoader.create(jar, parent)) {
            assert loader.payloadFirst().isEmpty() : "no spider class depends on payload Push: " + loader.payloadFirst();
            assert loader.loadClass("com.github.catvod.spider.Push").getClassLoader() != loader;
        }
    }

    /**
     * 桌面替身已过时（Kanqiu 写死的 88kanqiu.tv 已失效）：jar 自带同名类时一律用载荷版，
     * 哪怕没有别的类依赖它；jar 不带时仍是桌面版。
     */
    private static void outdatedStandInAlwaysComesFromPayload(Path work, ClassLoader parent) throws Exception {
        File jar = buildJar(work, "kanqiu", Map.of(
                "Kanqiu", "import com.github.catvod.crawler.Spider;\n"
                        + "public class Kanqiu extends Spider {\n"
                        + "  public String homeContent(boolean filter) { return \"payload-kanqiu\"; }\n"
                        + "}\n"));
        try (PayloadClassLoader loader = PayloadClassLoader.create(jar, parent)) {
            assert loader.payloadFirst().equals(java.util.Set.of("Kanqiu"))
                    : "a payload that ships Kanqiu must use it, got " + loader.payloadFirst();
            assert "payload-kanqiu".equals(callHomeContent(loader, "Kanqiu")) : "Kanqiu must come from the payload";
        }
        File other = buildJar(work, "no-kanqiu", Map.of(
                "Other", "import com.github.catvod.crawler.Spider;\n"
                        + "public class Other extends Spider {}\n"));
        try (PayloadClassLoader loader = PayloadClassLoader.create(other, parent)) {
            assert loader.payloadFirst().isEmpty() : "payload without Kanqiu: nothing flips, got " + loader.payloadFirst();
            assert loader.loadClass("com.github.catvod.spider.Kanqiu").getClassLoader() != loader
                    : "without a payload copy the desktop Kanqiu is still used";
        }
    }

    private static Object callHomeContent(ClassLoader loader, String simpleName) throws Exception {
        Class<?> c = loader.loadClass("com.github.catvod.spider." + simpleName);
        Object spider = c.getDeclaredConstructor().newInstance();
        return c.getMethod("homeContent", boolean.class).invoke(spider, false);
    }

    private static File buildJar(Path work, String name, Map<String, String> sources) throws IOException {
        JavaCompiler javac = ToolProvider.getSystemJavaCompiler();
        if (javac == null) throw new IllegalStateException("需要用 JDK 运行本测试（要现场编译夹具）");
        Path out = work.resolve(name + "-classes");
        Files.createDirectories(out);
        List<String> argv = new ArrayList<>(List.of("-nowarn", "-encoding", "UTF-8",
                "-cp", System.getProperty("java.class.path"), "-d", out.toString()));
        for (Map.Entry<String, String> e : sources.entrySet()) {
            // 键是简单类名 → spider 包；带点的键是全限定名，放进对应的包
            String fqcn = e.getKey().contains(".") ? e.getKey() : "com.github.catvod.spider." + e.getKey();
            int dot = fqcn.lastIndexOf('.');
            Path f = work.resolve(name + "-src").resolve(fqcn.replace('.', '/') + ".java");
            Files.createDirectories(f.getParent());
            Files.writeString(f, "package " + fqcn.substring(0, dot) + ";\n" + e.getValue(), StandardCharsets.UTF_8);
            argv.add(f.toString());
        }
        int rc = javac.run(null, null, null, argv.toArray(new String[0]));
        if (rc != 0) throw new IllegalStateException("fixture compile failed: " + rc);
        File jar = work.resolve(name + ".jar").toFile();
        try (OutputStream fos = Files.newOutputStream(jar.toPath()); JarOutputStream jos = new JarOutputStream(fos);
             Stream<Path> files = Files.walk(out)) {
            for (Path p : (Iterable<Path>) files.filter(Files::isRegularFile)::iterator) {
                jos.putNextEntry(new JarEntry(out.relativize(p).toString().replace('\\', '/')));
                jos.write(Files.readAllBytes(p));
                jos.closeEntry();
            }
        }
        return jar;
    }

    private static void deleteTree(Path root) {
        try (Stream<Path> s = Files.walk(root)) {
            s.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
        } catch (IOException ignored) {
        }
    }
}
