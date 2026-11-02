package android.animation;

import java.lang.reflect.Method;

/**
 * android.animation.ObjectAnimator 的桌面实现：每次取值更新时按 Android 的约定调用目标的
 * {@code set<属性名>(值)}（如 "alpha" 调 setAlpha(float)），因此 start() 返回后目标已处于终值状态。
 */
public final class ObjectAnimator extends ValueAnimator {

    private Object target;
    private String propertyName;

    public ObjectAnimator() {
    }

    private ObjectAnimator(Object target, String propertyName) {
        this.target = target;
        this.propertyName = propertyName;
    }

    public static ObjectAnimator ofFloat(Object target, String propertyName, float... values) {
        ObjectAnimator a = new ObjectAnimator(target, propertyName);
        a.setFloatValues(values);
        return a;
    }

    public static ObjectAnimator ofInt(Object target, String propertyName, int... values) {
        ObjectAnimator a = new ObjectAnimator(target, propertyName);
        a.setIntValues(values);
        return a;
    }

    public static ObjectAnimator ofArgb(Object target, String propertyName, int... values) {
        return ofInt(target, propertyName, values);
    }

    public static ObjectAnimator ofObject(Object target, String propertyName, TypeEvaluator<?> evaluator,
                                          Object... values) {
        ObjectAnimator a = new ObjectAnimator(target, propertyName);
        a.setObjectValues(values);
        a.setEvaluator(evaluator);
        return a;
    }

    @Override
    public ObjectAnimator setDuration(long duration) {
        super.setDuration(duration);
        return this;
    }

    @Override
    public void setTarget(Object target) {
        this.target = target;
    }

    public Object getTarget() {
        return target;
    }

    public void setPropertyName(String propertyName) {
        this.propertyName = propertyName;
    }

    public String getPropertyName() {
        return propertyName;
    }

    public void setAutoCancel(boolean cancel) {
    }

    @Override
    protected void dispatchUpdate() {
        applyToTarget(getAnimatedValue());
        super.dispatchUpdate();
    }

    /** 找不到对应 setter 时与 Android 一样只记日志、不抛异常。 */
    private void applyToTarget(Object value) {
        if (target == null || propertyName == null || propertyName.isEmpty() || value == null) return;
        String setter = "set" + Character.toUpperCase(propertyName.charAt(0)) + propertyName.substring(1);
        Class<?> primitive = value instanceof Float ? float.class : value instanceof Integer ? int.class : null;
        Method m = findSetter(target.getClass(), setter, primitive, value.getClass());
        if (m == null) {
            System.err.println("[ObjectAnimator] no setter " + setter + " on " + target.getClass().getName());
            return;
        }
        try {
            m.setAccessible(true);
            m.invoke(target, value);
        } catch (ReflectiveOperationException | RuntimeException e) {
            System.err.println("[ObjectAnimator] " + setter + " failed: " + e);
        }
    }

    private static Method findSetter(Class<?> type, String name, Class<?> primitive, Class<?> boxed) {
        for (Class<?> c = type; c != null; c = c.getSuperclass()) {
            for (Method m : c.getDeclaredMethods()) {
                if (!m.getName().equals(name) || m.getParameterCount() != 1) continue;
                Class<?> p = m.getParameterTypes()[0];
                if (p == primitive || p.isAssignableFrom(boxed)) return m;
            }
        }
        return null;
    }

    @Override
    public ObjectAnimator clone() {
        return (ObjectAnimator) super.clone();
    }
}
