package android.text.method;

/**
 * android.text.method.ScrollingMovementMethod：标记用单例。
 */
public class ScrollingMovementMethod implements MovementMethod {

    private static final ScrollingMovementMethod INSTANCE = new ScrollingMovementMethod();

    public static MovementMethod getInstance() {
        return INSTANCE;
    }
}
