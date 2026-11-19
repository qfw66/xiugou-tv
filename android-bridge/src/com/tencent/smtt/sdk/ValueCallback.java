package com.tencent.smtt.sdk;

/** X5 回调的独立二进制接口；不能替换成 android.webkit 同名类型。 */
public interface ValueCallback<T> {
    void onReceiveValue(T value);
}
