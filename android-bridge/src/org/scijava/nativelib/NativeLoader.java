package org.scijava.nativelib;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * 简化版 scijava-nativelib 的 NativeLoader（本机未发布到 Maven Central）。
 * 行为等价：按平台从 classpath（unicorn jar 的 natives/&lt;platform&gt;/ 目录）
 * 提取原生库到临时文件并 System.load。
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
        String suffix = fileName.substring(fileName.lastIndexOf('.'));
        File tmp = File.createTempFile(libName + "_", suffix);
        tmp.deleteOnExit();
        try (OutputStream out = new FileOutputStream(tmp)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        } finally {
            in.close();
        }
        System.load(tmp.getAbsolutePath());
        System.out.println("[NativeLoader] loaded " + resource + " -> " + tmp.getAbsolutePath());
    }
}
