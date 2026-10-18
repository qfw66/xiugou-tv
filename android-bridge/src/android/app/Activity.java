package android.app;

import android.content.Context;

/**
 * Minimal android.app.Activity stub；UI 调用按"立即在调用线程执行"处理。
 */
public class Activity extends Context {

    public void runOnUiThread(Runnable action) {
        if (action != null) action.run();
    }

    public boolean isFinishing() {
        return false;
    }

    public boolean isDestroyed() {
        return false;
    }

    public void finish() {
    }

    public void onCreate(android.os.Bundle savedInstanceState) {
    }

    public android.content.Intent getIntent() {
        return new android.content.Intent();
    }
}
