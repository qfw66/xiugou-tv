package com.wexfnw.libso;

import android.content.Context;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.Base64;
import java.util.Collections;
import java.util.HashSet;
import java.util.Random;
import java.util.Set;

import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 载荷 {@code com.wexfnw.libso.LoadNiMa} 的桌面等价实现。
 *
 * <p>原类的 native 方法由 ARM64 的 {@code libLoadNiMa.so} 提供，Windows 无法加载，
 * 70 个载荷类（约 20 个站点）一碰到它就 {@code NoClassDefFoundError}，表现为分类 0 条。
 * companion 的载荷 ClassLoader 是父优先，本类同名即可顶替载荷里的原类。
 *
 * <p>语义来自 unidbg 跑原 so 的取证（2026-10-27，{@code test/repro/LoadNiMaProbe.java}），
 * 并以真实响应做过逐字节比对：
 * <ul>
 *   <li>{@link #init}：读取屏蔽词表（UTF-8，一行一个）；</li>
 *   <li>{@link #contains}：与某一行完全相等才算命中（子串 / 超串都不算）；</li>
 *   <li>{@link #decode}：Base64 → AES-128-CBC/PKCS7，key = 当天 {@code yyyyMMdd} + {@code woshini8}，
 *       iv = {@code Wexfnwshinidieha}；</li>
 *   <li>{@link #decodedata}：同上，key = iv = {@code Wexfnwnbshinibaa}；</li>
 *   <li>解不开时两者都返回原 so 的固定提示语（载荷随后按非 JSON 走自己的失败分支）。</li>
 * </ul>
 * 日期按 Asia/Shanghai 取（服务端与原设备均在东八区）；当天解不开再试前一天 / 后一天，兜住跨零点。
 */
public class LoadNiMa {

    static final String FAILURE = "谁想破解，王二小放牛娃就是谁的爸爸。";
    private static final String DAILY_SUFFIX = "woshini8";
    private static final byte[] DAILY_IV = "Wexfnwshinidieha".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] DATA_KEY = "Wexfnwnbshinibaa".getBytes(StandardCharsets.US_ASCII);
    private static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");
    private static final DateTimeFormatter DAY = DateTimeFormatter.ofPattern("yyyyMMdd");

    private static volatile Set<String> words;

    public LoadNiMa() {
    }

    /** 载荷在下载完词表后调用：参数是 {@code <filesDir>/TV/.wexstring}。 */
    public static void init(String path) {
        words = readWords(path == null ? null : new File(path));
    }

    public static boolean contains(String text) {
        if (text == null) return false;
        Set<String> set = words;
        if (set == null) {
            // 载荷的 init 链路可能因别的宿主差异提前退出：按原默认位置懒加载一次
            set = readWords(new File(Context.get().getFilesDir(), "TV/.wexstring"));
            words = set;
        }
        return set.contains(text);
    }

    public static String decode(Context context, String cipherText) {
        return decode(cipherText, LocalDate.now(ZONE));
    }

    public static String decodedata(Context context, String cipherText) {
        String plain = aes(cipherText, DATA_KEY, DATA_KEY);
        return plain != null ? plain : FAILURE;
    }

    /** 载荷用它生成临时文件后缀（原类里的普通 Java 方法，名字保持原样）。 */
    public static String oOoOoOoOoOoOoO0o(int length) {
        final char[] alphabet = "abcdefghijklmnopqrstuvwxyz0123456789".toCharArray();
        Random random = new Random();
        StringBuilder sb = new StringBuilder(length);
        for (int i = 0; i < length; i++) sb.append(alphabet[random.nextInt(alphabet.length)]);
        return sb.toString();
    }

    static String decode(String cipherText, LocalDate today) {
        for (LocalDate day : new LocalDate[]{today, today.minusDays(1), today.plusDays(1)}) {
            byte[] key = (day.format(DAY) + DAILY_SUFFIX).getBytes(StandardCharsets.US_ASCII);
            String plain = aes(cipherText, key, DAILY_IV);
            if (plain != null) return plain;
        }
        return FAILURE;
    }

    /** 解密失败（非 Base64、长度不对、填充错、明文不是合法 UTF-8）返回 null。 */
    static String aes(String cipherText, byte[] key, byte[] iv) {
        if (cipherText == null) return null;
        try {
            byte[] raw = Base64.getMimeDecoder().decode(cipherText.trim());
            if (raw.length == 0 || raw.length % 16 != 0) return null;
            Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
            cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
            byte[] plain = cipher.doFinal(raw);
            // 错误 key 约有 1/256 概率恰好得到合法填充：再用严格 UTF-8 解码把乱码挡掉
            // （原 so 此时返回固定提示语；跨零点回退也靠这一步区分「哪一天的 key 才是对的」）
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(plain)).toString();
        } catch (Exception e) {
            return null;
        }
    }

    static Set<String> readWords(File file) {
        if (file == null || !file.isFile()) return Collections.emptySet();
        try {
            Set<String> set = new HashSet<>();
            for (String line : Files.readAllLines(file.toPath(), StandardCharsets.UTF_8)) {
                String word = line.strip();
                if (!word.isEmpty()) set.add(word);
            }
            return Collections.unmodifiableSet(set);
        } catch (Exception e) {
            return Collections.emptySet();
        }
    }
}
