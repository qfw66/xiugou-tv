package android.os;

import java.io.File;

/** 磁盘容量查询：按 4 KB 块折算 java.io.File 的容量（载荷只用来定磁盘缓存大小）。 */
public class StatFs {
    private static final long BLOCK = 4096L;
    private File file;

    public StatFs(String path) {
        this.file = new File(path);
    }

    public void restat(String path) {
        this.file = new File(path);
    }

    public long getBlockSizeLong() { return BLOCK; }
    public long getBlockCountLong() { return file.getTotalSpace() / BLOCK; }
    public long getAvailableBlocksLong() { return file.getUsableSpace() / BLOCK; }
    public long getFreeBlocksLong() { return file.getFreeSpace() / BLOCK; }
    public long getTotalBytes() { return file.getTotalSpace(); }
    public long getAvailableBytes() { return file.getUsableSpace(); }
    public long getFreeBytes() { return file.getFreeSpace(); }

    public int getBlockSize() { return (int) BLOCK; }
    public int getBlockCount() { return (int) Math.min(Integer.MAX_VALUE, getBlockCountLong()); }
    public int getAvailableBlocks() { return (int) Math.min(Integer.MAX_VALUE, getAvailableBlocksLong()); }
    public int getFreeBlocks() { return (int) Math.min(Integer.MAX_VALUE, getFreeBlocksLong()); }
}
