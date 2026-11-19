package com.github.catvod.utils;

import com.fongmi.companion.hardshell.FishNativeService;

/** 让真实载荷原生库在独立 ARM 模拟器执行，所有返回值与策略判断均来自载荷本身。 */
public final class FishNative {
    private FishNative() {}
    public static int _guardConfig(java.lang.String a0) { return (Integer) FishNativeService.nativeCall("_guardConfig(Ljava/lang/String;)I", a0); }
    public static boolean _guardReady() { return (Boolean) FishNativeService.nativeCall("_guardReady()Z"); }
    public static java.lang.String _honHonKeyId() { return (java.lang.String) FishNativeService.nativeCall("_honHonKeyId()Ljava/lang/String;"); }
    public static boolean _honHonReady() { return (Boolean) FishNativeService.nativeCall("_honHonReady()Z"); }
    public static java.lang.String _honHonRoute() { return (java.lang.String) FishNativeService.nativeCall("_honHonRoute()Ljava/lang/String;"); }
    public static byte[] _honHonServerPublicKey() { return (byte[]) FishNativeService.nativeCall("_honHonServerPublicKey()[B"); }
    public static byte[] _honHonSign(byte[] a0) { return (byte[]) FishNativeService.nativeCall("_honHonSign([B)[B", a0); }
    public static int _kChk(java.lang.String a0) { return (Integer) FishNativeService.nativeCall("_kChk(Ljava/lang/String;)I", a0); }
    public static java.lang.String _pan123ShareGetApi(java.lang.String a0, java.lang.String a1, java.lang.String a2, java.lang.String a3, int a4, int a5) { return (java.lang.String) FishNativeService.nativeCall("_pan123ShareGetApi(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;II)Ljava/lang/String;", a0, a1, a2, a3, a4, a5); }
    public static java.lang.String _pan123UnlimitedUrl(java.lang.String a0) { return (java.lang.String) FishNativeService.nativeCall("_pan123UnlimitedUrl(Ljava/lang/String;)Ljava/lang/String;", a0); }
    public static byte[] _secAesCbcDec(java.lang.String a0, java.lang.String a1, byte[] a2) { return (byte[]) FishNativeService.nativeCall("_secAesCbcDec(Ljava/lang/String;Ljava/lang/String;[B)[B", a0, a1, a2); }
    public static byte[] _secAesCbcEnc(java.lang.String a0, java.lang.String a1, byte[] a2) { return (byte[]) FishNativeService.nativeCall("_secAesCbcEnc(Ljava/lang/String;Ljava/lang/String;[B)[B", a0, a1, a2); }
    public static byte[] _secAesCbcEncJsonAccess(java.lang.String a0, java.lang.String a1, java.lang.String a2, java.lang.String a3, byte[] a4) { return (byte[]) FishNativeService.nativeCall("_secAesCbcEncJsonAccess(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;[B)[B", a0, a1, a2, a3, a4); }
    public static java.lang.String _secText(java.lang.String a0) { return (java.lang.String) FishNativeService.nativeCall("_secText(Ljava/lang/String;)Ljava/lang/String;", a0); }
    public static java.lang.String _sv(int a0) { return (java.lang.String) FishNativeService.nativeCall("_sv(I)Ljava/lang/String;", a0); }
    public static byte[] aesDec(byte[] a0, byte[] a1, byte[] a2) { return (byte[]) FishNativeService.nativeCall("aesDec([B[B[B)[B", a0, a1, a2); }
    public static byte[] aesEnc(byte[] a0, byte[] a1, byte[] a2) { return (byte[]) FishNativeService.nativeCall("aesEnc([B[B[B)[B", a0, a1, a2); }
    public static byte[] cKey(java.lang.String a0, java.lang.String a1) { return (byte[]) FishNativeService.nativeCall("cKey(Ljava/lang/String;Ljava/lang/String;)[B", a0, a1); }
    public static java.lang.String[] cfgUrls() { return (java.lang.String[]) FishNativeService.nativeCall("cfgUrls()[Ljava/lang/String;"); }
    public static void checkAlive() { FishNativeService.nativeCall("checkAlive()V"); }
    public static java.lang.String defCfg() { return (java.lang.String) FishNativeService.nativeCall("defCfg()Ljava/lang/String;"); }
    public static byte[] extDe(java.lang.String a0) { return (byte[]) FishNativeService.nativeCall("extDe(Ljava/lang/String;)[B", a0); }
    public static byte[] extEn(java.lang.String a0) { return (byte[]) FishNativeService.nativeCall("extEn(Ljava/lang/String;)[B", a0); }
    public static int fishGoAbiVersion() { return (Integer) FishNativeService.nativeCall("fishGoAbiVersion()I"); }
    public static long guardLease(int a0, java.lang.String a1) { return (Long) FishNativeService.nativeCall("guardLease(ILjava/lang/String;)J", a0, a1); }
    public static boolean guardUse(int a0, long a1, java.lang.String a2) { return (Boolean) FishNativeService.nativeCall("guardUse(IJLjava/lang/String;)Z", a0, a1, a2); }
    public static boolean hostAllowed() { return (Boolean) FishNativeService.nativeCall("hostAllowed()Z"); }
    public static int hostApply(java.lang.String a0) { return (Integer) FishNativeService.nativeCall("hostApply(Ljava/lang/String;)I", a0); }
    public static void hostExit(long a0) { FishNativeService.nativeCall("hostExit(J)V", a0); }
    public static void hostInit(android.content.Context a0) { FishNativeService.nativeCall("hostInit(Landroid/content/Context;)V", a0); }
    public static java.lang.String hostStatus() { return (java.lang.String) FishNativeService.nativeCall("hostStatus()Ljava/lang/String;"); }
    public static void nExit() { FishNativeService.nativeCall("nExit()V"); }
    public static boolean nKilled() { return (Boolean) FishNativeService.nativeCall("nKilled()Z"); }
    public static java.lang.String popupAck(long a0) { return (java.lang.String) FishNativeService.nativeCall("popupAck(J)Ljava/lang/String;", a0); }
    public static long popupArm(java.lang.String a0, java.lang.String a1) { return (Long) FishNativeService.nativeCall("popupArm(Ljava/lang/String;Ljava/lang/String;)J", a0, a1); }
    public static void popupCheck() { FishNativeService.nativeCall("popupCheck()V"); }
    public static boolean popupRequire(java.lang.String a0, java.lang.String a1, java.lang.String a2) { return (Boolean) FishNativeService.nativeCall("popupRequire(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z", a0, a1, a2); }
    public static void popupShown(long a0) { FishNativeService.nativeCall("popupShown(J)V", a0); }
    public static void popupViolation(long a0) { FishNativeService.nativeCall("popupViolation(J)V", a0); }
    public static java.lang.String rPub() { return (java.lang.String) FishNativeService.nativeCall("rPub()Ljava/lang/String;"); }
    private static void register() { FishNativeService.nativeCall("register()V"); }
    public static int spVer() { return (Integer) FishNativeService.nativeCall("spVer()I"); }
    public static java.lang.String ssKey() { return (java.lang.String) FishNativeService.nativeCall("ssKey()Ljava/lang/String;"); }
    public static int startGo(int a0, java.lang.String a1, java.lang.String a2, byte[] a3) { return (Integer) FishNativeService.nativeCall("startGo(ILjava/lang/String;Ljava/lang/String;[B)I", a0, a1, a2, a3); }
    public static void stop() { FishNativeService.nativeCall("stop()V"); }
    public static int svN() { return (Integer) FishNativeService.nativeCall("svN()I"); }
    public static byte[] urlDe(java.lang.String a0) { return (byte[]) FishNativeService.nativeCall("urlDe(Ljava/lang/String;)[B", a0); }
    public static byte[] urlEn(java.lang.String a0) { return (byte[]) FishNativeService.nativeCall("urlEn(Ljava/lang/String;)[B", a0); }
    public static void load(String path) { FishNativeService.load(path); }
    public static void loadAndRegister(String path) { load(path); }
    public static void requireReadOnly(java.io.File file) {
        if (file == null || !file.isFile()) throw new IllegalArgumentException("Fish 原生文件不存在");
        if (!file.setWritable(false, false) && file.canWrite()) throw new IllegalStateException("Fish 原生文件不能设为只读");
    }
}
