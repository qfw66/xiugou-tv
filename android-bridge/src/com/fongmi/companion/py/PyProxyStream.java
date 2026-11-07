package com.fongmi.companion.py;

import java.io.IOException;
import java.io.InputStream;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** One runner handle, pinned to its original child until EOF or close. */
final class PyProxyStream extends InputStream {
    private final PyRuntime owner;
    private final String handle;
    private final Runnable release;
    private final AtomicBoolean closed = new AtomicBoolean();
    private byte[] chunk = new byte[0];
    private int offset;
    private boolean eof;

    PyProxyStream(PyRuntime owner, String handle, Runnable release) {
        this.owner = owner;
        this.handle = handle;
        this.release = release;
    }

    @Override
    public synchronized int read() throws IOException {
        byte[] single = new byte[1];
        return read(single, 0, 1) == -1 ? -1 : single[0] & 255;
    }

    @Override
    public synchronized int read(byte[] bytes, int start, int length) throws IOException {
        Objects.checkFromIndexSize(start, length, bytes.length);
        if (length == 0) return 0;
        if (eof) return -1;
        if (closed.get()) throw new IOException("script stream closed");
        try {
            if (!owner.isAlive()) throw new IOException("script stream closed");
            if (offset == chunk.length) {
                byte[] next = owner.readStream(handle, 65536);
                if (closed.get()) throw new IOException("script stream closed");
                if (next == null) {
                    eof = true;
                    close();
                    return -1;
                }
                chunk = next;
                offset = 0;
            }
            int count = Math.min(length, chunk.length - offset);
            System.arraycopy(chunk, offset, bytes, start, count);
            offset += count;
            return count;
        } catch (IOException error) {
            close();
            throw error;
        }
    }

    @Override
    public void close() {
        if (!closed.compareAndSet(false, true)) return;
        try { owner.closeStream(handle); }
        finally { release.run(); }
    }
}
