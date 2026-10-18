package android.view;

/**
 * 极简 KeyEvent 桩：加固载荷 ProxyOrigin 的方法签名引用了该类
 * （dispatchKeyEvent(KeyEvent) 等），JVM 解析方法表时会强制加载。
 * 代理链路不涉及遥控器按键，这里只需要常量与空实现。
 */
public class KeyEvent {

    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MULTIPLE = 2;

    public static final int KEYCODE_UNKNOWN = 0;
    public static final int KEYCODE_BACK = 4;
    public static final int KEYCODE_DPAD_UP = 19;
    public static final int KEYCODE_DPAD_DOWN = 20;
    public static final int KEYCODE_DPAD_LEFT = 21;
    public static final int KEYCODE_DPAD_RIGHT = 22;
    public static final int KEYCODE_DPAD_CENTER = 23;
    public static final int KEYCODE_ENTER = 66;

    private final int action;
    private final int keyCode;

    public KeyEvent(int action, int keyCode) {
        this.action = action;
        this.keyCode = keyCode;
    }

    public int getAction() {
        return action;
    }

    public int getKeyCode() {
        return keyCode;
    }

    public int getRepeatCount() {
        return 0;
    }
}
