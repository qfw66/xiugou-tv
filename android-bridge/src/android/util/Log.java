package android.util;

/**
 * Minimal android.util.Log stub；输出到 stdout/stderr 以便伴随服务日志排查。
 */
public class Log {

    private static final boolean ENABLED = Boolean.parseBoolean(System.getProperty("companion.android.log", "false"));

    public static int v(String tag, String msg) {
        if (ENABLED) System.out.println("[V/" + tag + "] " + msg);
        return 0;
    }

    public static int v(String tag, String msg, Throwable tr) {
        if (ENABLED) {
            System.out.println("[V/" + tag + "] " + msg);
            if (tr != null) tr.printStackTrace();
        }
        return 0;
    }

    public static int d(String tag, String msg) {
        if (ENABLED) System.out.println("[D/" + tag + "] " + msg);
        return 0;
    }

    public static int d(String tag, String msg, Throwable tr) {
        if (ENABLED) {
            System.out.println("[D/" + tag + "] " + msg);
            if (tr != null) tr.printStackTrace();
        }
        return 0;
    }

    public static int i(String tag, String msg) {
        if (ENABLED) System.out.println("[I/" + tag + "] " + msg);
        return 0;
    }

    public static int i(String tag, String msg, Throwable tr) {
        if (ENABLED) {
            System.out.println("[I/" + tag + "] " + msg);
            if (tr != null) tr.printStackTrace();
        }
        return 0;
    }

    public static int w(String tag, String msg) {
        if (ENABLED) System.out.println("[W/" + tag + "] " + msg);
        return 0;
    }

    public static int w(String tag, String msg, Throwable tr) {
        if (ENABLED) {
            System.out.println("[W/" + tag + "] " + msg);
            if (tr != null) tr.printStackTrace();
        }
        return 0;
    }

    public static int w(String tag, Throwable tr) {
        if (ENABLED) {
            System.out.println("[W/" + tag + "] " + tr);
            if (tr != null) tr.printStackTrace();
        }
        return 0;
    }

    public static int e(String tag, String msg) {
        System.err.println("[E/" + tag + "] " + msg);
        return 0;
    }

    public static int e(String tag, String msg, Throwable tr) {
        System.err.println("[E/" + tag + "] " + msg);
        if (tr != null) tr.printStackTrace();
        return 0;
    }

    public static String getStackTraceString(Throwable tr) {
        if (tr == null) return "";
        java.io.StringWriter sw = new java.io.StringWriter();
        tr.printStackTrace(new java.io.PrintWriter(sw));
        return sw.toString();
    }
}
