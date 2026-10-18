package android.util;

/**
 * companion android shim：android.util.Pair
 *
 * 背景：top98_1.jar / Yoursmile.jar 等手机端 spider jar 中，多个 spider（如 XBiu）
 * 实例化时引用 android.util.Pair；桌面 companion 若无此桩类，会抛
 * NoClassDefFoundError: android/util/Pair，导致 DexSpiderLoader 回退 SpiderNull，
 * 客户端表现为"该站点获取不到数据"。
 */
public class Pair<F, S> {
    public final F first;
    public final S second;

    public Pair(F first, S second) {
        this.first = first;
        this.second = second;
    }

    public static <A, B> Pair<A, B> create(A a, B b) {
        return new Pair<A, B>(a, b);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        Pair<?, ?> p = (Pair<?, ?>) o;
        return java.util.Objects.equals(first, p.first) && java.util.Objects.equals(second, p.second);
    }

    @Override
    public int hashCode() {
        return java.util.Objects.hash(first, second);
    }

    @Override
    public String toString() {
        return "Pair{" + first + ", " + second + "}";
    }
}
