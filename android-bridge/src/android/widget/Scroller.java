package android.widget;

import android.content.Context;
import android.view.animation.Interpolator;

/**
 * 滚动位置计算器。与动画一致，桌面端不逐帧推进：startScroll / fling 后立即处于终点并标记完成，
 * 调用方读 getCurrX/Y 即得终值。
 */
public class Scroller {

    private final Interpolator interpolator;
    private int startX;
    private int startY;
    private int finalX;
    private int finalY;
    private int currX;
    private int currY;
    private int duration;
    private boolean finished = true;

    public Scroller(Context context) {
        this(context, null);
    }

    public Scroller(Context context, Interpolator interpolator) {
        this(context, interpolator, true);
    }

    public Scroller(Context context, Interpolator interpolator, boolean flywheel) {
        this.interpolator = interpolator;
    }

    public void startScroll(int startX, int startY, int dx, int dy) {
        startScroll(startX, startY, dx, dy, 250);
    }

    public void startScroll(int startX, int startY, int dx, int dy, int duration) {
        this.startX = startX;
        this.startY = startY;
        this.finalX = startX + dx;
        this.finalY = startY + dy;
        this.duration = duration;
        this.currX = startX;
        this.currY = startY;
        this.finished = false;
    }

    /** 惯性滚动直接落到边界内的起点（没有速度模型），保持位置不变并结束。 */
    public void fling(int startX, int startY, int velocityX, int velocityY,
                      int minX, int maxX, int minY, int maxY) {
        int x = Math.max(minX, Math.min(maxX, startX));
        int y = Math.max(minY, Math.min(maxY, startY));
        this.startX = startX;
        this.startY = startY;
        this.finalX = x;
        this.finalY = y;
        this.duration = 0;
        this.currX = startX;
        this.currY = startY;
        this.finished = false;
    }

    /**
     * 推进一步：首次调用跳到终点并返回 true（调用方据此刷新一次），之后返回 false。
     */
    public boolean computeScrollOffset() {
        if (finished) return false;
        currX = finalX;
        currY = finalY;
        finished = true;
        return true;
    }

    public void abortAnimation() {
        currX = finalX;
        currY = finalY;
        finished = true;
    }

    public final void forceFinished(boolean finished) {
        this.finished = finished;
    }

    public final boolean isFinished() {
        return finished;
    }

    public final int getCurrX() {
        return currX;
    }

    public final int getCurrY() {
        return currY;
    }

    public final int getStartX() {
        return startX;
    }

    public final int getStartY() {
        return startY;
    }

    public final int getFinalX() {
        return finalX;
    }

    public final int getFinalY() {
        return finalY;
    }

    public void setFinalX(int newX) {
        this.finalX = newX;
        this.finished = false;
    }

    public void setFinalY(int newY) {
        this.finalY = newY;
        this.finished = false;
    }

    public final int getDuration() {
        return duration;
    }

    public float getCurrVelocity() {
        return 0f;
    }

    public void extendDuration(int extend) {
        duration += extend;
    }

    public int timePassed() {
        return finished ? duration : 0;
    }

    public final void setFriction(float friction) {
    }

    Interpolator getInterpolator() {
        return interpolator;
    }
}
