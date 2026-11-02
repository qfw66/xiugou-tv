package org.scijava.nativelib;

import com.fongmi.companion.fs.NativeCache;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;

/**
 * 简化版 scijava-nativelib 的 NativeLoader（本机未发布到 Maven Central）。
 * 按平台从 classpath（unicorn jar 的 natives/&lt;platform&gt;/ 目录）取出原生库，
 * 经 {@link NativeCache} 按内容哈希落地复用后 System.load——不再每次在 %TEMP% 留一份随机名副本。
 */
public class NativeLoader {

    public static void loadLibrary(String libName, String[] searchPaths) throws IOException {
        String os = System.getProperty("os.name", "").toLowerCase();
        String arch = System.getProperty("os.arch", "").toLowerCase();
        String platform;
        String fileName;
        if (os.contains("win")) {
            platform = arch.contains("64") ? "windows_64" : "windows_32";
            fileName = libName + ".dll";
        } else if (os.contains("mac") || os.contains("darwin")) {
            platform = arch.contains("aarch64") ? "osx_arm64" : "osx_64";
            fileName = "lib" + libName + ".dylib";
        } else {
            platform = arch.contains("aarch64") ? "linux_arm64" : "linux_64";
            fileName = "lib" + libName + ".so";
        }
        String resource = "natives/" + platform + "/" + fileName;
        ClassLoader cl = NativeLoader.class.getClassLoader();
        InputStream in = cl.getResourceAsStream(resource);
        if (in == null) {
            throw new IOException("native library not found on classpath: " + resource);
        }
        NativeCache.sweepLegacyTemp();
        File lib = NativeCache.materialize(fileName, in);
        System.load(lib.getAbsolutePath());
        System.out.println("[NativeLoader] loaded " + resource + " -> " + lib.getAbsolutePath());
    }
}
