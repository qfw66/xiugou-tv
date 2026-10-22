package android.webkit;

import android.net.Uri;

import java.util.Map;

/**
 * android.webkit.WebResourceRequest：Android 里就是 interface，载荷以
 * {@code invokeinterface} 调用，本工程保持接口形态。
 */
public interface WebResourceRequest {

    Uri getUrl();

    boolean isForMainFrame();

    boolean isRedirect();

    boolean hasGesture();

    String getMethod();

    Map<String, String> getRequestHeaders();
}
