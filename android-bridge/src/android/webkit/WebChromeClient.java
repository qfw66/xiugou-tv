package android.webkit;

import android.graphics.Bitmap;

/** android.webkit.WebChromeClient 空实现（仅满足 {@link WebView#setWebChromeClient} 的签名）。 */
public class WebChromeClient {

    public void onProgressChanged(WebView view, int newProgress) {
    }

    public void onReceivedTitle(WebView view, String title) {
    }

    public void onReceivedIcon(WebView view, Bitmap icon) {
    }

    public boolean onJsAlert(WebView view, String url, String message, JsResult result) {
        return false;
    }

    public boolean onJsConfirm(WebView view, String url, String message, JsResult result) {
        return false;
    }

    public boolean onJsPrompt(WebView view, String url, String message, String defaultValue,
                              JsPromptResult result) {
        return false;
    }

    /** JS 弹窗结果的占位类型。 */
    public static class JsResult {
        public void confirm() {
        }

        public void cancel() {
        }
    }

    /** {@code onJsPrompt} 的结果类型。 */
    public static class JsPromptResult extends JsResult {
        public void confirm(String result) {
        }
    }
}
