package com.fongmi.companion.hardshell;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.*;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * Supplemental constructor/frame repair for the verified custom_spider.jar revision.
 * This is not a shell profile: it neither provisions native code nor changes identity.
 * Matching the original bytes keeps the pass and its cache invalidation off other sources.
 */
final class PanConfigRepair {
    private static final String CURRENT_SHA256 = "9353ae9a1d810ef5450b6fd4a9ccd309c109caf4fe8c999b3a1f65d001619728";
    private static final Set<String> SOURCE_SHA256 = Set.of(
            "4bdbd66546120668b5e03b74436489b4c0091b0d15cf2a9da438feff95caaaa8", CURRENT_SHA256,
            "c8513b6fec73c68037cf40b4b4d92908754aee8fb1cdb26939816385a53bfbbf");
    private static final String REPAIR_VERSION = "-panconfig-ctor" + new CtorInlineRepair().version() + "-v6";
    // Model Object() forwarders inlined in DEX; e/j are the cross-package catalog filter group/value DTOs.
    private static final Set<String> MODEL_BRIDGES = Set.of(
            "com/github/catvod/spider/merge/a/b", "com/github/catvod/spider/merge/a/e",
            "com/github/catvod/spider/merge/a/g", "com/github/catvod/spider/merge/a/j",
            "com/github/catvod/spider/merge/a/k", "com/github/catvod/spider/merge/a/m");

    private PanConfigRepair() {}

    static String stamp(File sourceJar) {
        return matches(sourceJar) ? REPAIR_VERSION : "";
    }

    static boolean repair(File converted, File sourceJar) {
        if (!matches(sourceJar)) return false;
        // Apply host-contract bridges before the constructor pass, which rebuilds all frames.
        exposeModelBridges(converted);
        if (!new CtorInlineRepair().repair(converted)) {
            throw new IllegalStateException("PanConfig constructor/frame repair did not complete");
        }
        return true;
    }

    private static void exposeModelBridges(File converted) {
        Path tmp = converted.toPath().resolveSibling(converted.getName() + ".panconfig.tmp");
        Set<String> remaining = new HashSet<>(MODEL_BRIDGES);
        boolean completionPatched = false;
        try {
            try (ZipFile zip = new ZipFile(converted);
                 ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(tmp))) {
                var entries = zip.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    byte[] data;
                    try (InputStream input = zip.getInputStream(entry)) { data = input.readAllBytes(); }
                    String name = entry.getName();
                    if (name.endsWith(".class") && remaining.remove(name.substring(0, name.length() - 6))) {
                        ClassNode node = new ClassNode();
                        new ClassReader(data).accept(node, 0);
                        MethodNode ctor = node.methods.stream().filter(method -> method.name.equals("<init>")
                                && method.desc.equals("()V")).findFirst().orElseThrow();
                        AbstractInsnNode[] code = Arrays.stream(ctor.instructions.toArray())
                                .filter(instruction -> instruction.getOpcode() >= 0).toArray(AbstractInsnNode[]::new);
                        if (!"java/lang/Object".equals(node.superName) || (ctor.access & Opcodes.ACC_PRIVATE) == 0
                                || !ctor.tryCatchBlocks.isEmpty() || code.length != 3
                                || !(code[0] instanceof VarInsnNode load) || load.getOpcode() != Opcodes.ALOAD || load.var != 0
                                || !(code[1] instanceof MethodInsnNode call) || call.getOpcode() != Opcodes.INVOKESPECIAL
                                || !call.owner.equals("java/lang/Object") || !call.name.equals("<init>") || !call.desc.equals("()V")
                                || code[2].getOpcode() != Opcodes.RETURN) {
                            throw new IllegalStateException("Unexpected PanConfig model constructor: " + node.name);
                        }
                        // Retain the original method body, fields, annotations and rebuilt frames.
                        ctor.access = (ctor.access & ~Opcodes.ACC_PRIVATE) | Opcodes.ACC_PUBLIC;
                        ClassWriter writer = new ClassWriter(0);
                        node.accept(writer);
                        data = writer.toByteArray();
                    } else if (name.equals("com/github/catvod/spider/PanConfig.class")) {
                        ClassNode node = new ClassNode();
                        new ClassReader(data).accept(node, 0);
                        repairCompletedLogin(node);
                        ClassWriter writer = new ClassWriter(0);
                        node.accept(writer);
                        data = writer.toByteArray();
                        completionPatched = true;
                    }
                    out.putNextEntry(new ZipEntry(name));
                    out.write(data);
                    out.closeEntry();
                }
            }
            if (!completionPatched) throw new IllegalStateException("Missing PanConfig login completion bridge");
            if (!remaining.isEmpty()) throw new IllegalStateException("Missing PanConfig model constructors: " + remaining);
            Files.move(tmp, converted.toPath(), StandardCopyOption.REPLACE_EXISTING);
            System.out.println("[PanConfig/repair] Exposed " + MODEL_BRIDGES.size() + " existing Object() model constructor bridges");
        } catch (IOException e) {
            throw new IllegalStateException("Cannot repair PanConfig host contracts", e);
        } finally {
            try { Files.deleteIfExists(tmp); } catch (IOException ignored) {}
        }
    }
    /** Normal Dialog.close() returns null; this revision only handled completion in its exception path. */
    private static void repairCompletedLogin(ClassNode node) {
        MethodNode scan = node.methods.stream().filter(method -> method.name.equals("h")
                && method.desc.equals("(Lcom/github/catvod/spider/PanConfig$Account;Ljava/lang/String;)Ljava/lang/String;"))
                .findFirst().orElseThrow(() -> new IllegalStateException("Missing PanConfig scan method"));
        MethodInsnNode show = null;
        for (AbstractInsnNode instruction : scan.instructions) {
            if (instruction instanceof MethodInsnNode call && call.owner.equals("com/github/catvod/utils/Dialog")
                    && call.name.equals("show") && call.desc.equals("(Lorg/json/JSONObject;)Lorg/json/JSONObject;")) {
                if (show != null) throw new IllegalStateException("Ambiguous PanConfig QR dialog");
                show = call;
            }
        }
        if (show == null || !(nextCode(show) instanceof VarInsnNode result) || result.getOpcode() != Opcodes.ASTORE)
            throw new IllegalStateException("Unexpected PanConfig dialog result");
        JumpInsnNode completed = null;
        VarInsnNode attempt = null;
        FieldInsnNode done = null;
        int position = scan.instructions.indexOf(show);
        for (TryCatchBlockNode block : scan.tryCatchBlocks) {
            if (!"java/lang/IllegalStateException".equals(block.type)
                    || scan.instructions.indexOf(block.start) > position || position >= scan.instructions.indexOf(block.end)) continue;
            AbstractInsnNode caught = nextCode(block.handler), load = nextCode(caught), field = nextCode(load), jump = nextCode(field);
            if (caught instanceof VarInsnNode store && store.getOpcode() == Opcodes.ASTORE && store.var == result.var
                    && load instanceof VarInsnNode local && local.getOpcode() == Opcodes.ALOAD
                    && field instanceof FieldInsnNode flag && flag.getOpcode() == Opcodes.GETFIELD
                    && flag.owner.equals("com/github/catvod/spider/PanConfig$LoginAttempt") && flag.name.equals("e") && flag.desc.equals("Z")
                    && jump instanceof JumpInsnNode branch && branch.getOpcode() == Opcodes.IFNE) {
                attempt = local; done = flag; completed = branch;
            }
        }
        if (completed == null) throw new IllegalStateException("Unexpected PanConfig completion guard");
        InsnList bridge = new InsnList();
        bridge.add(new VarInsnNode(Opcodes.ALOAD, attempt.var));
        bridge.add(new FieldInsnNode(Opcodes.GETFIELD, done.owner, done.name, done.desc));
        bridge.add(new JumpInsnNode(Opcodes.IFNE, completed.label));
        scan.instructions.insert(result, bridge);
    }

    private static AbstractInsnNode nextCode(AbstractInsnNode instruction) {
        if (instruction == null) return null;
        do { instruction = instruction.getNext(); } while (instruction != null && instruction.getOpcode() < 0);
        return instruction;
    }

    private static boolean matches(File sourceJar) {
        return SOURCE_SHA256.contains(fingerprint(sourceJar));
    }

    private static String fingerprint(File sourceJar) {
        if (sourceJar == null || !sourceJar.isFile()) return "";
        try (InputStream input = Files.newInputStream(sourceJar.toPath())) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[16384];
            for (int size; (size = input.read(buffer)) != -1;) digest.update(buffer, 0, size);
            return HexFormat.of().formatHex(digest.digest());
        } catch (IOException e) {
            throw new UncheckedIOException("Cannot fingerprint payload for bytecode repair", e);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
