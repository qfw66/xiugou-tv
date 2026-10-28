package android.text;

/**
 * android.text.TextWatcher：输入框内容变化回调。宿主回填用户输入时会按 before / on / after 顺序触发。
 */
public interface TextWatcher {

    void beforeTextChanged(CharSequence s, int start, int count, int after);

    void onTextChanged(CharSequence s, int start, int before, int count);

    void afterTextChanged(Editable s);
}
