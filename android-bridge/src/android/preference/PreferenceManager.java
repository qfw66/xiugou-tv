package android.preference;

import android.content.Context;
import android.content.SharedPreferences;

/** android.preference.PreferenceManager 桩。 */
public class PreferenceManager {

    public static final String KEY_HAS_SET_DEFAULT_VALUES = "_has_set_default_values";

    public static SharedPreferences getDefaultSharedPreferences(Context context) {
        Context ctx = context != null ? context : Context.get();
        return ctx.getSharedPreferences(ctx.getPackageName() + "_preferences", 0);
    }
}
