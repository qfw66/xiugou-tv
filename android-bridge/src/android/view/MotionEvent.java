package android.view;

/**
 * android.view.MotionEvent 的最小实现：桌面端不产生触摸事件，只为载荷的触摸回调签名可解析。
 */
public class MotionEvent {

    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_CANCEL = 3;

    public static final int ACTION_OUTSIDE = 4;
    public static final int ACTION_POINTER_DOWN = 5;
    public static final int ACTION_POINTER_UP = 6;
    public static final int ACTION_MASK = 0xff;

    public int getAction() {
        return ACTION_CANCEL;
    }

    public int getActionMasked() {
        return getAction() & ACTION_MASK;
    }

    public int getActionIndex() {
        return 0;
    }

    public int getPointerCount() {
        return 1;
    }

    public int getPointerId(int pointerIndex) {
        return 0;
    }

    public float getX(int pointerIndex) {
        return getX();
    }

    public float getY(int pointerIndex) {
        return getY();
    }

    public long getEventTime() {
        return 0L;
    }

    public long getDownTime() {
        return 0L;
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
