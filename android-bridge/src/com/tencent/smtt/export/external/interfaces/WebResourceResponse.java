package com.tencent.smtt.export.external.interfaces;

import java.io.InputStream;
import java.util.Map;

/** X5 拦截响应使用与系统 WebView 一致的元数据存储。 */
public class WebResourceResponse extends android.webkit.WebResourceResponse {
    public WebResourceResponse(String mimeType, String encoding, int statusCode, String reasonPhrase,
                               Map<String, String> headers, InputStream data) {
        super(mimeType, encoding, statusCode, reasonPhrase, headers, data);
    }
}
