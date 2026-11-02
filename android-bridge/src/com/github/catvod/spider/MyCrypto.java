package com.github.catvod.spider;

import com.fongmi.companion.hardshell.PayloadCryptoService;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 载荷 {@code MyCrypto} 的桌面实现。
 *
 * <h3>为什么需要它</h3>
 * aowu 系载荷把密码学实现放进 Android ARM 的 {@code assets/awenc-v8.so}，Java 侧全是
 * {@code native} 方法，纯 JVM 直接调用必然 {@code UnsatisfiedLinkError}。
 *
 * <h3>为什么放在这个包名</h3>
 * 载荷由 {@code URLClassLoader} 加载，parent 是 companion 的 classloader，
 * 因此同名类会**优先取到这里的实现**，载荷里的 native 版本被遮蔽。
 *
 * <h3>两类方法</h3>
 * <ul>
 *   <li>9 个标准算法（md5 / sha1 / sha256 / hmacSha1 / hmacSha256 / AES-CBC ×2 / AES-ECB ×2）
 *       用 JDK 实现，不走模拟器。</li>
 *   <li>站点专用的 13 个（extDe / fsDec / MyXo / TSaowu / awSign / czlc / get / huyaWs /
 *       huyaWup / hxqSign / ngrSign / v7d / v7e）经 {@link PayloadCryptoService} 交给 unidbg
 *       执行载荷自带的 awenc-v8.so（它在 {@code JNI_OnLoad} 里 {@code RegisterNatives}）。
 *       服务不可用时：{@code extDe} 按 UTF-8 恒等兜底，其余抛 {@link UnsupportedOperationException}。</li>
 *   <li>{@code rungo} 不在 awenc 的注册表里，保持不支持。</li>
 * </ul>
 * 打点请用 {@code -Dmycrypto.trace=1}，它会把每次调用的真实入参打出来。
 */
public class MyCrypto {

    /** 载荷里的编译期常量，原值 0（由 class 文件 ConstantValue 读出）。 */
    public static final int o0OoO0oO0oOoO0O0oO = 0;

    /** 调用追踪开关：{@code -Dmycrypto.trace=1}，只用于定位站点到底用了哪些算法。 */
    private static final boolean TRACE = "1".equals(System.getProperty("mycrypto.trace"));

    private static void trace(String name, Object... args) {
        if (!TRACE) return;
        StringBuilder sb = new StringBuilder("[MyCrypto] ").append(name).append('(');
        for (int i = 0; i < args.length; i++) {
            if (i > 0) sb.append(", ");
            Object a = args[i];
            if (a == null) {
                sb.append("null");
            } else if (a instanceof byte[]) {
                byte[] b = (byte[]) a;
                sb.append("bytes[").append(b.length).append("]");
            } else if (a instanceof String) {
                String t = (String) a;
                sb.append('"').append(t.length() > 40 ? t.substring(0, 40) + "…" : t).append('"');
            } else {
                sb.append(a);
            }
        }
        System.out.println(sb.append(')'));
    }

    private static byte[] result(String name, byte[] out) {
        if (TRACE) {
            System.out.println("[MyCrypto] " + name + " = "
                    + (out == null ? "null" : "bytes[" + out.length + "]"));
        }
        return out;
    }

    /**
     * extDe 结果缓存：同一份密文整族站点要解几百次，而模拟器逐条执行单次约 400 ms；
     * 解密是确定性的，按密文缓存即可。上限防止异常输入撑爆内存。
     */
    private static final Map<String, byte[]> EXT_DE_CACHE = new ConcurrentHashMap<>();
    private static final int EXT_DE_CACHE_LIMIT = 64;

    public MyCrypto() {
    }

    // ------------------------------------------------------------------ 摘要

    public static byte[] md5(byte[] data) {
        trace("md5", data);
        return result("md5", digest("MD5", data));
    }

    public static byte[] sha1(byte[] data) {
        trace("sha1", data);
        return result("sha1", digest("SHA-1", data));
    }

    public static byte[] sha256(byte[] data) {
        trace("sha256", data);
        return result("sha256", digest("SHA-256", data));
    }

    // ------------------------------------------------------------------ HMAC

    public static byte[] hmacSha1(byte[] key, byte[] data) {
        trace("hmacSha1", key, data);
        return result("hmacSha1", hmac("HmacSHA1", key, data));
    }

    public static byte[] hmacSha256(byte[] key, byte[] data) {
        trace("hmacSha256", key, data);
        return result("hmacSha256", hmac("HmacSHA256", key, data));
    }

    // ------------------------------------------------------------------ AES

    public static byte[] aesCbcEncrypt(byte[] data, byte[] key, byte[] iv) {
        trace("aesCbcEncrypt", data, key, iv);
        return result("aesCbcEncrypt", aes(Cipher.ENCRYPT_MODE, "AES/CBC/PKCS5Padding", key, iv, data));
    }

    public static byte[] aesCbcDecrypt(byte[] data, byte[] key, byte[] iv) {
        trace("aesCbcDecrypt", data, key, iv);
        return result("aesCbcDecrypt", aes(Cipher.DECRYPT_MODE, "AES/CBC/PKCS5Padding", key, iv, data));
    }

    public static byte[] aesEcbEncrypt(byte[] data, byte[] key) {
        trace("aesEcbEncrypt", data, key);
        return result("aesEcbEncrypt", aes(Cipher.ENCRYPT_MODE, "AES/ECB/PKCS5Padding", key, null, data));
    }

    public static byte[] aesEcbDecrypt(byte[] data, byte[] key) {
        trace("aesEcbDecrypt", data, key);
        return result("aesEcbDecrypt", aes(Cipher.DECRYPT_MODE, "AES/ECB/PKCS5Padding", key, null, data));
    }

    // ------------------------------------------------------------------ 站点专用（载荷 native）

    public static byte[] MyXo(byte[] data) {
        return nativeCall("MyXo", "MyXo([B)[B", data);
    }

    public static byte[] TSaowu(byte[] data, String arg) {
        return nativeCall("TSaowu", "TSaowu([BLjava/lang/String;)[B", data, arg);
    }

    public static byte[] awSign(byte[] data, String arg) {
        return nativeCall("awSign", "awSign([BLjava/lang/String;)[B", data, arg);
    }

    public static byte[] czlc(byte[] data) {
        return nativeCall("czlc", "czlc([B)[B", data);
    }

    public static byte[] extDe(String arg) {
        trace("extDe", arg);
        byte[] cached = arg == null ? null : EXT_DE_CACHE.get(arg);
        if (cached != null) return result("extDe", cached.clone());
        PayloadCryptoService.Reply reply = PayloadCryptoService.call("extDe(Ljava/lang/String;)[B", arg);
        if (reply != null) {
            byte[] out = reply.bytes();
            if (arg != null && out != null && EXT_DE_CACHE.size() < EXT_DE_CACHE_LIMIT) {
                EXT_DE_CACHE.put(arg, out.clone());
            }
            return result("extDe", out);
        }
        // 服务不可用时按 UTF-8 恒等兜底：抛异常会让整条配置初始化直接失败，
        // 而 ext 是明文的源恒等就是正确结果。
        return result("extDe", arg == null ? null : arg.getBytes(StandardCharsets.UTF_8));
    }

    public static byte[] fsDec(byte[] data, String a1, String a2) {
        return nativeCall("fsDec", "fsDec([BLjava/lang/String;Ljava/lang/String;)[B", data, a1, a2);
    }

    public static byte[] get(byte[] data) {
        return nativeCall("get", "get([B)[B", data);
    }

    public static byte[] huyaWs(byte[] data, String arg) {
        return nativeCall("huyaWs", "huyaWs([BLjava/lang/String;)[B", data, arg);
    }

    public static byte[] huyaWup(byte[] data, String arg) {
        return nativeCall("huyaWup", "huyaWup([BLjava/lang/String;)[B", data, arg);
    }

    public static byte[] hxqSign(int v, byte[] data, String arg) {
        return nativeCall("hxqSign", "hxqSign(I[BLjava/lang/String;)[B", v, data, arg);
    }

    public static byte[] ngrSign(String a1, byte[] data, String a2) {
        return nativeCall("ngrSign", "ngrSign(Ljava/lang/String;[BLjava/lang/String;)[B", a1, data, a2);
    }

    public static void rungo(String a1, String a2, String a3) {
        throw unsupported("rungo", a1, a2, a3);
    }

    public static byte[] v7d(byte[] a1, byte[] a2, String a3, String a4, String a5) {
        return nativeCall("v7d", "v7d([B[BLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)[B",
                a1, a2, a3, a4, a5);
    }

    public static byte[] v7e(byte[] a1, byte[] a2, byte[] a3, String a4) {
        return nativeCall("v7e", "v7e([B[B[BLjava/lang/String;)[B", a1, a2, a3, a4);
    }

    // ------------------------------------------------------------------ 实现

    /** 转发到载荷 native；服务不可用时抛出可定位的异常，而不是含义模糊的 UnsatisfiedLinkError。 */
    private static byte[] nativeCall(String name, String signature, Object... args) {
        trace(name, args);
        PayloadCryptoService.Reply reply = PayloadCryptoService.call(signature, args);
        if (reply == null) throw unsupported(name);
        return result(name, reply.bytes());
    }

    private static UnsupportedOperationException unsupported(String name) {
        return new UnsupportedOperationException(
                "MyCrypto." + name + " 是载荷 native 方法，代调服务不可用（见 hardshell-*-crypto.log）");
    }

    private static UnsupportedOperationException unsupported(String name, Object... args) {
        trace(name, args);
        return unsupported(name);
    }

    private static byte[] digest(String algorithm, byte[] data) {
        if (data == null) return null;
        try {
            return MessageDigest.getInstance(algorithm).digest(data);
        } catch (Exception e) {
            throw new IllegalStateException(algorithm + " 不可用", e);
        }
    }

    private static byte[] hmac(String algorithm, byte[] key, byte[] data) {
        if (key == null || data == null) return null;
        try {
            Mac mac = Mac.getInstance(algorithm);
            mac.init(new SecretKeySpec(key, algorithm));
            return mac.doFinal(data);
        } catch (Exception e) {
            throw new IllegalStateException(algorithm + " 不可用", e);
        }
    }

    private static byte[] aes(int mode, String transformation, byte[] key, byte[] iv, byte[] data) {
        if (key == null || data == null) return null;
        try {
            Cipher cipher = Cipher.getInstance(transformation);
            SecretKeySpec spec = new SecretKeySpec(key, "AES");
            if (iv != null && iv.length > 0) {
                cipher.init(mode, spec, new IvParameterSpec(iv));
            } else {
                cipher.init(mode, spec);
            }
            return cipher.doFinal(data);
        } catch (Exception e) {
            throw new IllegalStateException("AES(" + transformation + ") 失败", e);
        }
    }
}
