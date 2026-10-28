package android.graphics.drawable;

import java.util.ArrayList;
import java.util.List;

/**
 * android.graphics.drawable.StateListDrawable：按状态切换的背景；桌面端只保存，不参与呈现。
 */
public class StateListDrawable extends Drawable {

    private final List<int[]> states = new ArrayList<>();
    private final List<Drawable> drawables = new ArrayList<>();

    public void addState(int[] stateSet, Drawable drawable) {
        states.add(stateSet == null ? new int[0] : stateSet.clone());
        drawables.add(drawable);
    }

    public int getStateCount() {
        return drawables.size();
    }
}
