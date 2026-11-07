package com.fongmi.companion.guard;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;
import java.util.stream.Stream;

/** Filesystem regression tests for the payload lookup used by GuardDecryptor.main. */
public final class GuardDecryptorPayloadTest {
    private static int passed;
    private static int failed;

    public static void main(String[] args) throws Exception {
        run("old saved payload", () -> findsOnly("config.db.saved"));
        run("old direct payload", () -> findsOnly("config.db"));
        run("new saved payload", () -> findsOnly("config.jar.saved"));
        run("new direct payload", () -> findsOnly("config.jar"));
        run("missing and empty payloads", GuardDecryptorPayloadTest::missingAndEmpty);
        run("directory is not a payload", GuardDecryptorPayloadTest::skipsDirectory);
        run("unrelated files are ignored", GuardDecryptorPayloadTest::ignoresUnrelated);
        run("old names and saved backups keep priority", GuardDecryptorPayloadTest::keepsPriority);
        System.out.println("GuardDecryptorPayloadTest: " + passed + " passed, " + failed + " failed");
        if (failed != 0) throw new AssertionError("payload lookup regressions: " + failed);
    }

    private static void findsOnly(String name) throws Exception {
        try (Fixture fixture = new Fixture()) {
            Path payload = fixture.write("sharedb/" + name, new byte[] {0, (byte) 0x80, (byte) 0xff});
            expectPath(payload, GuardDecryptor.findPayload(fixture.root.toFile()));
            check(Arrays.equals(new byte[] {0, (byte) 0x80, (byte) 0xff}, Files.readAllBytes(payload)),
                    "discovery must leave payload bytes untouched");
        }
    }

    private static void missingAndEmpty() throws Exception {
        try (Fixture fixture = new Fixture()) {
            check(GuardDecryptor.findPayload(fixture.root.resolve("absent").toFile()) == null,
                    "missing cache must return no payload");
            check(GuardDecryptor.findPayload(fixture.root.toFile()) == null,
                    "empty cache must return no payload");
            for (String name : new String[] {"config.db.saved", "config.db", "config.jar.saved", "config.jar"}) {
                fixture.write("sharedb/" + name, new byte[0]);
            }
            check(GuardDecryptor.findPayload(fixture.root.toFile()) == null,
                    "zero-byte candidates must return no payload");
            Path payload = fixture.write("sharedb/config.db", new byte[] {42});
            expectPath(payload, GuardDecryptor.findPayload(fixture.root.toFile()));
        }
    }

    private static void skipsDirectory() throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.write("sharedb/config.db.saved/nested-payload", new byte[] {1});
            Path payload = fixture.write("sharedb/config.db", new byte[] {2});
            expectPath(payload, GuardDecryptor.findPayload(fixture.root.toFile()));
            Files.delete(payload);
            check(GuardDecryptor.findPayload(fixture.root.toFile()) == null,
                    "a nonempty candidate directory must not be returned");
        }
    }

    private static void ignoresUnrelated() throws Exception {
        try (Fixture fixture = new Fixture()) {
            for (String name : new String[] {
                    "sharedb/other.jar.saved", "sharedb/payload.jar", "sharedb/config.jar.part",
                    "sharedb/config.db.saved.saved", "sharedb/nested/config.jar.saved",
                    "other/config.jar.saved", "config.db.saved", "config.jar.saved",
            }) {
                fixture.write(name, new byte[] {1});
            }
            check(GuardDecryptor.findPayload(fixture.root.toFile()) == null,
                    "only known names directly under sharedb may be selected");
        }
    }

    private static void keepsPriority() throws Exception {
        try (Fixture fixture = new Fixture()) {
            Path oldSaved = fixture.write("sharedb/config.db.saved", new byte[] {1});
            Path oldDirect = fixture.write("sharedb/config.db", new byte[] {2});
            Path newSaved = fixture.write("sharedb/config.jar.saved", new byte[] {3});
            Path newDirect = fixture.write("sharedb/config.jar", new byte[] {4});
            expectPath(oldSaved, GuardDecryptor.findPayload(fixture.root.toFile()));
            Files.write(oldSaved, new byte[0]);
            expectPath(oldDirect, GuardDecryptor.findPayload(fixture.root.toFile()));
            Files.write(oldDirect, new byte[0]);
            expectPath(newSaved, GuardDecryptor.findPayload(fixture.root.toFile()));
            Files.write(newSaved, new byte[0]);
            expectPath(newDirect, GuardDecryptor.findPayload(fixture.root.toFile()));
        }
    }

    private static void expectPath(Path expected, File actual) {
        check(actual != null && expected.equals(actual.toPath()),
                "expected " + expected.getFileName() + ", got " + actual);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void run(String label, CheckedTest test) {
        try {
            test.run();
            passed++;
            System.out.println("PASS " + label);
        } catch (Throwable failure) {
            failed++;
            System.err.println("FAIL " + label + ": " + failure);
            failure.printStackTrace(System.err);
        }
    }

    private interface CheckedTest {
        void run() throws Exception;
    }

    private static final class Fixture implements AutoCloseable {
        final Path root = Files.createTempDirectory("guard-payload-test-").toAbsolutePath().normalize();

        Fixture() throws Exception {
        }

        Path write(String relative, byte[] bytes) throws Exception {
            Path file = root.resolve(relative);
            Files.createDirectories(file.getParent());
            return Files.write(file, bytes);
        }

        @Override
        public void close() throws Exception {
            Path tempRoot = new File(System.getProperty("java.io.tmpdir")).toPath().toAbsolutePath().normalize();
            check(root.getParent().equals(tempRoot) && root.getFileName().toString().startsWith("guard-payload-test-"),
                    "refuse cleanup outside the test temporary root");
            try (Stream<Path> paths = Files.walk(root)) {
                for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) {
                    Files.delete(path);
                }
            }
        }
    }
}
