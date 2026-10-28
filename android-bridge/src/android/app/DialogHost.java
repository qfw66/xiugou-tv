package android.app;

import android.view.View;

/**
 * 桌面端扩展点（不是 Android API）：把载荷对窗口 / 弹窗 / Toast / 剪贴板 / 外部跳转的调用交给宿主呈现。
 *
 * <p>Android 上这些调用由系统窗口服务完成；桌面 JVM 没有窗口，只能把「界面结构」交给宿主
 * （companion 的 {@code UiBridge}，再转给 Flutter）渲染。L1 只依赖这个抽象类，不反向依赖 L3：
 * 未安装宿主时一律走空实现，保持原来「静默无界面」的行为。
 */
public abstract class DialogHost {

    /** 控件树的全局锁：载荷线程构建 / 修改控件与宿主线程读取快照互斥。 */
    public static final Object TREE_LOCK = new Object();

    private static final DialogHost NONE = new DialogHost() {
    };

    private static volatile DialogHost current = NONE;

    public static DialogHost get() {
        return current;
    }

    public static void install(DialogHost host) {
        current = host == null ? NONE : host;
    }

    /** 弹窗即将显示（{@link Dialog#show()}）。 */
    public void onShow(Dialog dialog) {
    }

    /** 弹窗已关闭（{@link Dialog#dismiss()}）。 */
    public void onDismiss(Dialog dialog) {
    }

    /** 控件内容或结构变化：宿主据此刷新仍在显示的弹窗。 */
    public void onChanged(View view) {
    }

    /** 弹窗自身的标题 / 消息 / 按钮 / 列表变化（不属于控件树的部分）。 */
    public void onDialogChanged(Dialog dialog) {
    }

    public void onToast(CharSequence text) {
    }

    /** {@code Intent.ACTION_VIEW} 之类的外部跳转（打开网页 / 唤起 App）。 */
    public void onOpenUri(String uri, String mimeType) {
    }

    public void onClipboard(CharSequence text) {
    }

    /**
     * 对应 Android 的「投递到主线程」。未安装宿主时同步执行，与 {@link android.os.Handler#post} 的既有行为一致。
     */
    public void post(Runnable runnable) {
        if (runnable != null) runnable.run();
    }
}
