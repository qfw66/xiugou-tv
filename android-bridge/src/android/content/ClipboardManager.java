package android.content;

import android.app.DialogHost;

/**
 * android.content.ClipboardManager：载荷写剪贴板（如「115 cookie 已复制」）时交给宿主写入系统剪贴板。
 *
 * <p>读取只返回本进程最近一次写入的内容，不读取系统剪贴板。
 */
public class ClipboardManager {

    private volatile ClipData primaryClip;

    public void setPrimaryClip(ClipData clip) {
        this.primaryClip = clip;
        if (clip != null && clip.getItemCount() > 0) {
            CharSequence text = clip.getItemAt(0).getText();
            if (text != null) DialogHost.get().onClipboard(text);
        }
    }

    public ClipData getPrimaryClip() {
        return primaryClip;
    }

    public boolean hasPrimaryClip() {
        return primaryClip != null;
    }

    public void clearPrimaryClip() {
        primaryClip = null;
    }

    /** 旧 API（{@code android.text.ClipboardManager}）的等价写法。 */
    public void setText(CharSequence text) {
        setPrimaryClip(ClipData.newPlainText("text", text));
    }

    public CharSequence getText() {
        ClipData clip = primaryClip;
        return clip == null ? null : clip.getItemAt(0).getText();
    }
}
