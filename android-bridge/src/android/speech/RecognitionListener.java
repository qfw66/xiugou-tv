package android.speech;

import android.os.Bundle;

/** 语音识别回调的二进制兼容契约，不代表桌面提供识别服务。 */
public interface RecognitionListener {
    void onReadyForSpeech(Bundle params);

    void onBeginningOfSpeech();

    void onRmsChanged(float rmsdB);

    void onBufferReceived(byte[] buffer);

    void onEndOfSpeech();

    void onError(int error);

    void onResults(Bundle results);

    void onPartialResults(Bundle partialResults);

    void onEvent(int eventType, Bundle params);
}
