package android.animation;

/**
 * 插值器：把动画进度 [0,1] 映射为输出进度。桌面端动画一步到终值，插值器只在载荷主动调用时生效。
 */
public interface TimeInterpolator {
    float getInterpolation(float input);
}
