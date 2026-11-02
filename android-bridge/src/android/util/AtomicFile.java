package android.util;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/**
 * 原子文件写入，语义与 AOSP 一致：写到 {@code 原名.new}，完成后改名覆盖原文件；
 * 失败则删除新文件、原文件不受影响。载荷用它持久化网盘登录态等配置，必须真实落盘。
 */
public class AtomicFile {

    private final File baseName;
    private final File newName;
    private final File legacyBackupName;

    public AtomicFile(File baseName) {
        this.baseName = baseName;
        this.newName = new File(baseName.getPath() + ".new");
        this.legacyBackupName = new File(baseName.getPath() + ".bak");
    }

    public File getBaseFile() {
        return baseName;
    }

    public void delete() {
        baseName.delete();
        newName.delete();
        legacyBackupName.delete();
    }

    public FileOutputStream startWrite() throws IOException {
        // 旧版本留下的 .bak 说明上次写入中断，以它为准恢复
        if (legacyBackupName.exists()) {
            Files.move(legacyBackupName.toPath(), baseName.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
        try {
            return new FileOutputStream(newName);
        } catch (FileNotFoundException e) {
            File parent = newName.getParentFile();
            if (parent == null || !(parent.isDirectory() || parent.mkdirs())) {
                throw new IOException("Failed to create directory for " + newName, e);
            }
            return new FileOutputStream(newName);
        }
    }

    public void finishWrite(FileOutputStream str) {
        if (str == null) return;
        try {
            str.getFD().sync();
        } catch (IOException e) {
            Log.e("AtomicFile", "Failed to sync file output stream", e);
        }
        try {
            str.close();
        } catch (IOException e) {
            Log.e("AtomicFile", "Failed to close file output stream", e);
        }
        try {
            Files.move(newName.toPath(), baseName.toPath(), StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            try {
                Files.move(newName.toPath(), baseName.toPath(), StandardCopyOption.REPLACE_EXISTING);
            } catch (IOException e2) {
                Log.e("AtomicFile", "Failed to rename " + newName + " to " + baseName, e2);
            }
        }
    }

    public void failWrite(FileOutputStream str) {
        if (str == null) return;
        try {
            str.close();
        } catch (IOException e) {
            Log.e("AtomicFile", "Failed to close file output stream", e);
        }
        if (!newName.delete()) Log.e("AtomicFile", "Failed to delete new file " + newName);
    }

    public FileInputStream openRead() throws FileNotFoundException {
        if (legacyBackupName.exists()) {
            try {
                Files.move(legacyBackupName.toPath(), baseName.toPath(), StandardCopyOption.REPLACE_EXISTING);
            } catch (IOException e) {
                Log.e("AtomicFile", "Failed to restore " + legacyBackupName, e);
            }
        }
        // 只有 .new 而没有正式文件时说明写入未完成，丢弃它
        if (newName.exists() && baseName.exists()) newName.delete();
        return new FileInputStream(baseName);
    }

    public boolean exists() {
        return baseName.exists() || legacyBackupName.exists();
    }

    public long getLastModifiedTime() {
        if (legacyBackupName.exists()) return legacyBackupName.lastModified();
        return baseName.lastModified();
    }

    public byte[] readFully() throws IOException {
        try (FileInputStream stream = openRead()) {
            return stream.readAllBytes();
        }
    }
}
