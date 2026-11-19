package com.thegrizzlylabs.sardineandroid;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;

/** 载荷实际调用的 WebDAV 契约，失败必须向调用方报告而非返回假空数据。 */
public interface Sardine {
    void setCredentials(String username, String password);
    List<DavResource> list(String url) throws IOException;
    boolean exists(String url) throws IOException;
    void createDirectory(String url) throws IOException;
    void put(String url, File file, String contentType) throws IOException;
    InputStream get(String url) throws IOException;
}
