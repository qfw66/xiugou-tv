package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;

/** androidx 版 PreferenceManager：与 {@link android.preference.PreferenceManager} 用同一份默认偏好文件。 */
public class PreferenceManager {

    public static SharedPreferences getDefaultSharedPreferences(Context context) {
        return android.preference.PreferenceManager.getDefaultSharedPreferences(context);
    }
}
