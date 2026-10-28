package android.text.method;

/**
 * android.text.method.LinkMovementMethod：标记用单例。
 */
public class LinkMovementMethod extends ScrollingMovementMethod {

    private static final LinkMovementMethod INSTANCE = new LinkMovementMethod();

    public static MovementMethod getInstance() {
        return INSTANCE;
    }
}
