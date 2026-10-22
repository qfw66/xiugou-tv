package android.webkit;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.Map;

/** android.webkit.WebResourceResponse 空实现（只用于 {@code shouldInterceptRequest} 的返回类型）。 */
public class WebResourceResponse {

    private String mimeType;
    private String encoding;
    private int statusCode = 200;
    private String reasonPhrase;
    private Map<String, String> responseHeaders;
    private InputStream data;

    public WebResourceResponse(String mimeType, String encoding, InputStream data) {
        this.mimeType = mimeType;
        this.encoding = encoding;
        this.data = data;
    }

    public WebResourceResponse(String mimeType, String encoding, int statusCode,
                               String reasonPhrase, Map<String, String> responseHeaders,
                               InputStream data) {
        this.mimeType = mimeType;
        this.encoding = encoding;
        this.statusCode = statusCode;
        this.reasonPhrase = reasonPhrase;
        this.responseHeaders = responseHeaders;
        this.data = data;
    }

    public WebResourceResponse(boolean loadFromNetwork, String mimeType, String encoding,
                               int statusCode, String reasonPhrase,
                               Map<String, String> responseHeaders, InputStream data) {
        this(mimeType, encoding, statusCode, reasonPhrase, responseHeaders, data);
    }

    public void setMimeType(String mimeType) {
        this.mimeType = mimeType;
    }

    public String getMimeType() {
        return mimeType;
    }

    public void setEncoding(String encoding) {
        this.encoding = encoding;
    }

    public String getEncoding() {
        return encoding;
    }

    public void setStatusCode(int statusCode) {
        this.statusCode = statusCode;
    }

    public int getStatusCode() {
        return statusCode;
    }

    public void setReasonPhrase(String reasonPhrase) {
        this.reasonPhrase = reasonPhrase;
    }

    public String getReasonPhrase() {
        return reasonPhrase;
    }

    public void setResponseHeaders(Map<String, String> headers) {
        this.responseHeaders = headers;
    }

    public Map<String, String> getResponseHeaders() {
        return responseHeaders;
    }

    public void setData(InputStream data) {
        this.data = data;
    }

    public InputStream getData() {
        return data != null ? data : new ByteArrayInputStream(new byte[0]);
    }
}
