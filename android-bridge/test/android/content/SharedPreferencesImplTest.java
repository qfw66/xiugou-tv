package android.content;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Base64;
import java.util.Map;

/** Standalone regression test: run with assertions enabled (-ea). */
public final class SharedPreferencesImplTest {
    public static void main(String[] args) throws Exception {
        File dir = Files.createTempDirectory("xiugou-prefs-test").toFile();
        try {
            writesAndReloadsAllScalarTypes(dir);
            migratesLegacyRecordsWithBase64Padding(dir);
            handlesNullKeyRemovalAcrossReload(dir);
            skipsBrokenRecordsInMixedFiles(dir);
            commitReportsMoveFailureAndCleansTemporaryFile(dir);
        } finally {
            deleteTree(dir);
        }
    }

    private static void writesAndReloadsAllScalarTypes(File dir) throws Exception {
        SharedPreferencesImpl first = new SharedPreferencesImpl("round-trip", dir);
        assert first.edit()
                .putString("quarkCookie", "__pus=secret; 中文=值")
                .putString(null, "null-key")
                .putInt("int", 7)
                .putLong("long", 8L)
                .putFloat("float", 1.5f)
                .putBoolean("bool", true)
                .commit();

        SharedPreferencesImpl second = new SharedPreferencesImpl("round-trip", dir);
        assert "__pus=secret; 中文=值".equals(second.getString("quarkCookie", null));
        assert "null-key".equals(second.getString(null, null));
        assert second.getInt("int", 0) == 7;
        assert second.getLong("long", 0) == 8L;
        assert second.getFloat("float", 0) == 1.5f;
        assert second.getBoolean("bool", false);

        String disk = Files.readString(new File(dir, "round-trip.json").toPath());
        assert disk.startsWith("v2\t") : disk;
        assert !disk.contains("secret") : "values must remain encoded";
    }

    private static void migratesLegacyRecordsWithBase64Padding(File dir) throws Exception {
        File file = new File(dir, "legacy.json");
        String content = legacy('s', "quarkCookie", "cookie-value")
                + legacy('b', "enabled", "true")
                + legacy('i', "count", "12");
        Files.writeString(file.toPath(), content, StandardCharsets.UTF_8);

        SharedPreferencesImpl prefs = new SharedPreferencesImpl("legacy", dir);
        assert "cookie-value".equals(prefs.getString("quarkCookie", null));
        assert prefs.getBoolean("enabled", false);
        assert prefs.getInt("count", 0) == 12;
        assert Files.readString(file.toPath()).startsWith("v2\t");
        SharedPreferencesImpl afterSecondRestart = new SharedPreferencesImpl("legacy", dir);
        assert "cookie-value".equals(afterSecondRestart.getString("quarkCookie", null));
    }

    private static void handlesNullKeyRemovalAcrossReload(File dir) {
        SharedPreferencesImpl prefs = new SharedPreferencesImpl("null-remove", dir);
        assert prefs.edit().putString(null, "value").commit();
        assert prefs.contains(null);
        assert prefs.edit().remove(null).commit();
        assert !prefs.contains(null);
        assert !new SharedPreferencesImpl("null-remove", dir).contains(null);
    }

    private static void skipsBrokenRecordsInMixedFiles(File dir) throws Exception {
        File file = new File(dir, "partial.json");
        String v2 = "v2\ts\ts\t" + Base64.getUrlEncoder().withoutPadding()
                .encodeToString("second".getBytes(StandardCharsets.UTF_8))
                + "\t" + Base64.getUrlEncoder().withoutPadding()
                .encodeToString("two".getBytes(StandardCharsets.UTF_8)) + "\n";
        Files.writeString(file.toPath(), "broken\n" + legacy('s', "good", "value")
                + "v2\tb\ts\tYmFk\tTk9UQk9PTEVBTg\n" + v2 + "truncated=");
        SharedPreferencesImpl prefs = new SharedPreferencesImpl("partial", dir);
        assert "value".equals(prefs.getString("good", null));
        assert "two".equals(prefs.getString("second", null));
        assert prefs.getAll().equals(Map.of("good", "value", "second", "two"));
        SharedPreferencesImpl restarted = new SharedPreferencesImpl("partial", dir);
        assert restarted.getAll().equals(Map.of("good", "value", "second", "two"));
    }

    private static void commitReportsMoveFailureAndCleansTemporaryFile(File dir) throws Exception {
        // 目标位置被非空目录占住：原子替换必然失败，commit 必须如实返回 false，且不留下临时文件。
        File blocked = new File(dir, "move-fail.json");
        assert blocked.mkdirs();
        Files.writeString(new File(blocked, "keep").toPath(), "x");
        SharedPreferencesImpl prefs = new SharedPreferencesImpl("move-fail", dir);
        assert !prefs.edit().putString("quarkCookie", "v").commit() : "commit must report save failure";
        File[] leftovers = dir.listFiles((d, name) -> name.startsWith("move-fail.json.") && name.endsWith(".tmp"));
        assert leftovers != null && leftovers.length == 0 : "temporary file must be cleaned";
        assert "v".equals(prefs.getString("quarkCookie", null)) : "in-memory value still usable";
    }

    private static String legacy(char tag, String key, String value) {
        Base64.Encoder encoder = Base64.getEncoder();
        return tag + "\t"
                + encoder.encodeToString(key.getBytes(StandardCharsets.UTF_8)) + "="
                + encoder.encodeToString(value.getBytes(StandardCharsets.UTF_8)) + "\n";
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }
}
