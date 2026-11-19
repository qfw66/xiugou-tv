package android.speech;

import android.content.Context;
import android.content.Intent;

/** 桌面不访问麦克风；请求识别时通过标准客户端错误回调结束。 */
public final class SpeechRecognizer {
    public static final int ERROR_CLIENT = 5;

    private RecognitionListener listener;

    private SpeechRecognizer() {
    }

    public static SpeechRecognizer createSpeechRecognizer(Context context) {
        return new SpeechRecognizer();
    }

    public void setRecognitionListener(RecognitionListener listener) {
        this.listener = listener;
    }

    public void startListening(Intent intent) {
        RecognitionListener current = listener;
        if (current != null) current.onError(ERROR_CLIENT);
    }

    public void stopListening() {
    }
}
