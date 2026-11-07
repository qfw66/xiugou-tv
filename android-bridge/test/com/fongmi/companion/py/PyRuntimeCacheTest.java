package com.fongmi.companion.py;

import com.fongmi.companion.JsonCodec;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

/** Standalone integration test using only synthetic cache values and a temporary user.home. */
public final class PyRuntimeCacheTest {
    private static final String VALUE = "synthetic-cache-value";
    private static final String SCRIPT =
            "import os\n"
            + "from base.spider import Spider as BaseSpider\n"
            + "class Spider(BaseSpider):\n"
            + "    def __init__(self):\n"
            + "        self.at_start = self.getCache('login')\n"
            + "    def cached(self):\n"
            + "        return self.at_start\n"
            + "    def store(self):\n"
            + "        self.setCache('login', '" + VALUE + "')\n"
            + "        return self.getCache('login')\n"
            + "    def cache_directory(self):\n"
            + "        return os.environ.get('XIUGOU_CACHE_DIR')\n";

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && "child".equals(args[0])) {
            child(args[1], new File(args[2]));
            return;
        }
        Path root = Files.createTempDirectory("xiugou-py-runtime-test-").toRealPath();
        try {
            Path home = Files.createDirectories(root.resolve("home"));
            Path source = Files.createDirectories(root.resolve("scripts")).resolve("source.py");
            Files.write(source, SCRIPT.getBytes(StandardCharsets.UTF_8));
            Path other = Files.createDirectories(root.resolve("other")).resolve("source.py");
            Files.write(other, SCRIPT.getBytes(StandardCharsets.UTF_8));
            Path alias = source.getParent().resolve("..").resolve("scripts").resolve("source.py");
            runChild(home, source, "write");
            runChild(home, alias, "read");
            runChild(home, other, "empty");
            Files.write(source, (SCRIPT + "\nREVISION = 2\n").getBytes(StandardCharsets.UTF_8));
            runChild(home, source, "read");
            Path cache = home.resolve(".xiugou_tv_companion").resolve("py-cache");
            try (Stream<Path> files = Files.list(cache)) {
                check(files.filter(p -> p.toString().endsWith(".json")).count() == 1,
                        "one script must own one persistent cache file");
            }
            try (Stream<Path> files = Files.list(source.getParent())) {
                check(files.noneMatch(p -> p.toString().endsWith(".json")),
                        "cache must not be stored beside source code");
            }
            System.out.println("PyRuntimeCacheTest OK (4 fresh JVM/Python sessions)");
        } finally {
            check(root.isAbsolute() && root.getFileName().toString().startsWith("xiugou-py-runtime-test-"),
                    "cleanup must remain inside the generated test root");
            try (Stream<Path> paths = Files.walk(root)) {
                for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) {
                    Files.deleteIfExists(path);
                }
            }
        }
    }

    private static void runChild(Path home, Path script, String mode) throws Exception {
        String java = new File(new File(System.getProperty("java.home"), "bin"), "java").getAbsolutePath();
        ProcessBuilder builder = new ProcessBuilder(java,
                "-Duser.home=" + home,
                "-Dxiugou.python=" + System.getProperty("xiugou.python", "python"),
                "-Dxiugou.test.pyshell=" + System.getProperty("xiugou.test.pyshell", "companion/pyshell"),
                "-cp", System.getProperty("java.class.path"),
                PyRuntimeCacheTest.class.getName(), "child", mode, script.toString());
        builder.environment().put("HOME", home.toString());
        builder.environment().put("USERPROFILE", home.toString());
        builder.environment().put("PYTHONDONTWRITEBYTECODE", "1");
        builder.environment().put("XIUGOU_CACHE_DIR", home.resolve("ignored-inherited-cache").toString());
        Process process = builder.inheritIO().start();
        if (!process.waitFor(30, TimeUnit.SECONDS)) {
            process.destroyForcibly().waitFor();
            throw new AssertionError("test JVM did not finish within 30 seconds");
        }
        check(process.exitValue() == 0, "test JVM failed: " + mode);
    }

    private static void child(String mode, File script) throws Exception {
        Path home = new File(System.getProperty("user.home")).toPath();
        check(home.isAbsolute() && home.getParent().getFileName().toString().startsWith("xiugou-py-runtime-test-"),
                "test requires an isolated home");
        File expectedShell = new File(System.getProperty("xiugou.test.pyshell", "companion/pyshell"));
        check(PyRuntime.shellDir().getCanonicalFile().equals(expectedShell.getCanonicalFile()),
                "test must run the explicitly selected pyshell");
        try (PyRuntime runtime = PyRuntime.start(script, "", home.resolve("runner.log").toFile())) {
            Object directory = JsonCodec.parse(runtime.callJson("cache_directory", args()));
            check(home.resolve(".xiugou_tv_companion").resolve("py-cache").toString().equals(directory),
                    "host must inject its data directory instead of inheriting an arbitrary cache location");
            Object cached = JsonCodec.parse(runtime.callJson("cached", args()));
            if ("read".equals(mode)) {
                check(VALUE.equals(cached), "cache must survive a fresh JVM and be readable in __init__");
            } else {
                check(cached == null, "different scripts must not share cache entries");
            }
            if ("write".equals(mode)) {
                check(VALUE.equals(JsonCodec.parse(runtime.callJson("store", args()))),
                        "setCache must retain its in-memory value");
            }
        }
    }

    private static List<Object> args(Object... values) {
        return Arrays.asList(values);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
