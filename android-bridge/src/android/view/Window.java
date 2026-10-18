package android.view;

import android.graphics.drawable.Drawable;

/**
 * Minimal android.view.Window stub。
 */
public class Window {

    public View getDecorView() {
        return null;
    }

    public void setContentView(View view) {
    }

    public void setContentView(int layoutResID) {
    }

    public void setLayout(int width, int height) {
    }

    public void setGravity(int gravity) {
    }

    public void setFlags(int flags, int mask) {
    }

    public void clearFlags(int flags) {
    }

    public void addFlags(int flags) {
    }

    public void setBackgroundDrawable(Drawable drawable) {
    }

    public void setDimAmount(float amount) {
    }

    public void setType(int type) {
    }

    public void setSoftInputMode(int mode) {
    }

    public WindowManager.LayoutParams getAttributes() {
        return new WindowManager.LayoutParams();
    }

    public void setAttributes(WindowManager.LayoutParams params) {
    }

    public View findViewById(int id) {
        return null;
    }
}
