package com.github.catvod.net;

import org.json.JSONObject;

/** JSON options used by the modern Java spider SDK. Times are milliseconds. */
public final class NetOptions {
    final JSONObject json;
    private NetOptions(JSONObject json) { this.json = json; }
    public static NetOptions from(String json) {
        try { return new NetOptions(new JSONObject(json == null || json.isBlank() ? "{}" : json)); }
        catch (org.json.JSONException e) { throw new IllegalArgumentException("Invalid network options"); }
    }
    long timeout(String name, long fallback) {
        long value = json.optLong(name, fallback);
        if (value <= 0 || value > 120_000) throw new IllegalArgumentException("Invalid network timeout");
        return value;
    }
}
