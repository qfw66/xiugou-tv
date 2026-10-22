package android.content.pm;

import java.util.Arrays;

/** android.content.pm.Signature 桩：只承载字节与相等语义。 */
public class Signature {

    private final byte[] bytes;
    private int hash;

    public Signature(byte[] signature) {
        this.bytes = signature == null ? new byte[0] : signature.clone();
    }

    public byte[] toByteArray() {
        return bytes.clone();
    }

    public void update() {
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Signature)) return false;
        return Arrays.equals(bytes, ((Signature) o).bytes);
    }

    @Override
    public int hashCode() {
        if (hash == 0) hash = Arrays.hashCode(bytes) | 1;
        return hash;
    }

    @Override
    public String toString() {
        return "Signature(" + bytes.length + "B)";
    }
}
