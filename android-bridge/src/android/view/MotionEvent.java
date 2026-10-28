package android.view;

/**
 * android.view.MotionEvent 的最小实现：桌面端不产生触摸事件，只为载荷的触摸回调签名可解析。
 */
public class MotionEvent {

    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_CANCEL = 3;

    public int getAction() {
        return ACTION_CANCEL;
    }

    public float getX() {
        return 0f;
    }

    public float getY() {
        return 0f;
    }

    public float getRawX() {
        return 0f;
    }

    public float getRawY() {
        return 0f;
    }
}
