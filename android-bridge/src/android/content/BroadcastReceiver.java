package android.content;

/** 桌面没有系统广播，onReceive 不会被调用。 */
public abstract class BroadcastReceiver {
    public abstract void onReceive(Context context, Intent intent);
}
