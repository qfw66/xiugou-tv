package com.thegrizzlylabs.sardineandroid;

import java.net.URI;
import java.util.Date;

/** 保留 Sardine 的解码路径语义与装箱大小描述符。 */
public final class DavResource {
    private final URI href;
    private final boolean directory;
    private final long contentLength;
    private final Date modified;

    public DavResource(URI href, boolean directory, long contentLength, Date modified) {
        this.href = href;
        this.directory = directory;
        this.contentLength = contentLength;
        this.modified = modified == null ? null : new Date(modified.getTime());
    }

    public String getPath() {
        return href.getPath();
    }

    public String getName() {
        String path = getPath();
        if (path.endsWith("/")) path = path.substring(0, path.length() - 1);
        return path.substring(path.lastIndexOf('/') + 1);
    }

    public boolean isDirectory() {
        return directory;
    }

    public Long getContentLength() {
        return contentLength;
    }

    public Date getModified() {
        return modified == null ? null : new Date(modified.getTime());
    }
}
