package android.text;

/**
 * android.text.Layout：桌面端不排版，{@code TextView.getLayout()} 恒为 null；
 * 本类只为载荷里引用它的方法签名可解析。
 */
public abstract class Layout {

    public abstract int getLineCount();

    public abstract int getLineTop(int line);

    public int getLineBottom(int line) {
        return getLineTop(line + 1);
    }

    public int getLineBaseline(int line) {
        return getLineBottom(line);
    }

    public int getLineForOffset(int offset) {
        return 0;
    }

    public float getPrimaryHorizontal(int offset) {
        return 0f;
    }
}
