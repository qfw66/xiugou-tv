package android.text.method;

/**
 * android.text.method.ArrowKeyMovementMethod：标记用单例。
 */
public class ArrowKeyMovementMethod implements MovementMethod {

    private static final ArrowKeyMovementMethod INSTANCE = new ArrowKeyMovementMethod();

    public static MovementMethod getInstance() {
        return INSTANCE;
    }
}
