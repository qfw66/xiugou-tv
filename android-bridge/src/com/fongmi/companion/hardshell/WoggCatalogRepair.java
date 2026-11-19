package com.fongmi.companion.hardshell;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

final class WoggCatalogRepair {
    private static final Set<String> SOURCE_SHA256 = Set.of(
            "4bdbd66546120668b5e03b74436489b4c0091b0d15cf2a9da438feff95caaaa8",
            "9353ae9a1d810ef5450b6fd4a9ccd309c109caf4fe8c999b3a1f65d001619728",
            "c8513b6fec73c68037cf40b4b4d92908754aee8fb1cdb26939816385a53bfbbf");
    private static final String VERSION = "-wogg-catalog-v1";
    private static final String CLASS_NAME = "com/github/catvod/spider/Wogg$Catalog";
    private static final String ENTRY_NAME = CLASS_NAME + ".class";
    private static final String PRIVATE_CTOR_SHA256 = "a73239fbb70fc64fa3efb8b0837c6431c324c5bcf8587e9463c9f06027a9f942";
    private static final String PACKAGE_CTOR_SHA256 = "99a835868840c18d2c9ecf40abcd813a36d90264a06b5c1468e7a7876216df79";

    private WoggCatalogRepair() {}

    static String stamp(File source) { return matches(source) ? VERSION : ""; }

    static boolean repair(File converted, File source) {
        if (!matches(source)) return false;
        Path pending = converted.toPath().resolveSibling(converted.getName() + ".wogg.tmp");
        try {
            byte[] replacement;
            try (ZipFile zip = new ZipFile(converted)) {
                if (zip.stream().filter(entry -> entry.getName().equals(ENTRY_NAME)).count() != 1) {
                    throw new IllegalStateException("Missing or ambiguous verified Wogg Catalog class");
                }
                byte[] original;
                try (InputStream input = zip.getInputStream(zip.getEntry(ENTRY_NAME))) { original = input.readAllBytes(); }
                String fingerprint = hash(original);
                if (fingerprint.equals(PACKAGE_CTOR_SHA256)) return false;
                if (!fingerprint.equals(PRIVATE_CTOR_SHA256)) {
                    throw new IllegalStateException("Unknown converted Wogg Catalog revision");
                }
                replacement = packageConstructor(original);
                if (!hash(replacement).equals(PACKAGE_CTOR_SHA256)) {
                    throw new IllegalStateException("Wogg Catalog repair changed more than constructor access");
                }
                try (ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(pending))) {
                    var entries = zip.entries();
                    while (entries.hasMoreElements()) {
                        ZipEntry entry = entries.nextElement();
                        output.putNextEntry(new ZipEntry(entry.getName()));
                        if (entry.getName().equals(ENTRY_NAME)) {
                            output.write(replacement);
                        } else {
                            try (InputStream input = zip.getInputStream(entry)) { input.transferTo(output); }
                        }
                        output.closeEntry();
                    }
                }
            }
            Files.move(pending, converted.toPath(), StandardCopyOption.REPLACE_EXISTING);
            System.out.println("[Wogg/repair] Verified Catalog constructor package-access bridge applied");
            return true;
        } catch (IOException failure) {
            throw new IllegalStateException("Cannot repair verified Wogg Catalog access", failure);
        } finally {
            try { Files.deleteIfExists(pending); } catch (IOException ignored) {}
        }
    }

    private static byte[] packageConstructor(byte[] original) {
        ClassReader reader = new ClassReader(original);
        ClassWriter writer = new ClassWriter(reader, 0);
        int[] constructors = {0};
        reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                if (name.equals("<init>") && descriptor.equals("()V")) {
                    if (access != Opcodes.ACC_PRIVATE) throw new IllegalStateException("Unexpected Wogg Catalog constructor access");
                    constructors[0]++;
                    access &= ~Opcodes.ACC_PRIVATE;
                }
                return super.visitMethod(access, name, descriptor, signature, exceptions);
            }
        }, 0);
        if (constructors[0] != 1) throw new IllegalStateException("Unexpected Wogg Catalog constructor count");
        return writer.toByteArray();
    }

    private static boolean matches(File source) {
        if (source == null || !source.isFile()) return false;
        try (InputStream input = Files.newInputStream(source.toPath())) {
            MessageDigest digest = digest();
            byte[] buffer = new byte[16384];
            for (int size; (size = input.read(buffer)) != -1;) digest.update(buffer, 0, size);
            return SOURCE_SHA256.contains(HexFormat.of().formatHex(digest.digest()));
        } catch (IOException failure) {
            throw new UncheckedIOException("Cannot fingerprint source for Wogg access repair", failure);
        }
    }

    private static String hash(byte[] bytes) { return HexFormat.of().formatHex(digest().digest(bytes)); }

    private static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
}
