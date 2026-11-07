package android.content.res;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;

/** 桌面没有 APK assets：open 一律 FileNotFoundException（与安卓找不到资源时一致）。 */
public class AssetManager implements AutoCloseable {
    public static final int ACCESS_STREAMING = 2;

    public InputStream open(String fileName) throws IOException {
        throw new FileNotFoundException(fileName);
    }

    public InputStream open(String fileName, int accessMode) throws IOException {
        return open(fileName);
    }

    public String[] list(String path) throws IOException {
        return new String[0];
    }

    @Override
    public void close() {
    }
}
