package com.fongmi.companion;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 解析阶段标签：回答「卡在哪一步」。
 *
 * <p>动机：加固站点点亮失败时，日志里往往只剩一句混淆异常
 * （如 {@code InstantiationError: merge.b1.g}）或 {@code {"code":0,"data":""}}，
 * 无法区分是「下载失败」「解密失败」「本地代理没起」还是「类没找到」。
 * 于是把每个可失败环节标上阶段，随自检结果与 `/spider/call` 错误一起返回。
 *
 * <p>两条通道：
 * <ul>
 *   <li>线程内：{@link #current()}，供同一线程内「加载 → 自检」直接读取；</li>
 *   <li>按 tag：{@link #forTag(String)}，因为 RPC 的 worker 线程与 HTTP 响应线程不是同一个。</li>
 * </ul>
 * 阶段只记录**失败**；成功路径不写，避免无意义的状态堆积。
 */
public final class ParseStage {

    /** jar 规格解析（路径/URL/缓存命中判定）。 */
    public static final String RESOLVE = "resolve";
    /** 下载失败（网络、404、超时）。 */
    public static final String DOWNLOAD = "download";
    /** 内容与配置声明的 md5 不符。 */
    public static final String MD5 = "md5";
    /** 加固壳解密失败/超时。 */
    public static final String DECRYPT = "decrypt";
    /** dex → jvm jar 转换失败。 */
    public static final String DEX2JAR = "dex2jar";
    /** Init / InitOrigin 注入失败（缺 android.* shim 等）。 */
    public static final String INIT = "init";
    /** 本地代理宿主启动失败或端口注入失败。 */
    public static final String PROXY = "proxy";
    /** 载荷内没有可用的 Spider 子类，或候选不唯一。 */
    public static final String CLASS = "class";
    /** 构造函数失败。 */
    public static final String INSTANTIATE = "instantiate";
    /** 方法调用自身抛错（homeContent / categoryContent ...）。 */
    public static final String CALL = "call";

    /** 一次失败记录。 */
    public static final class Failure {
        public final String stage;
        public final String detail;
        public final long at = System.currentTimeMillis();

        Failure(String stage, String detail) {
            this.stage = stage;
            this.detail = detail;
        }

        public String describe() {
            return stage + ": " + detail;
        }
    }

    private static final ThreadLocal<String> TAG = new ThreadLocal<>();
    private static final ThreadLocal<Failure> CURRENT = new ThreadLocal<>();
    private static final Map<String, Failure> BY_TAG = new ConcurrentHashMap<>();
    /** 防止 tag 无界增长（tag 由「方法@站点」构成，配置切换时可能很多）。 */
    private static final int MAX_TAGS = 512;

    private ParseStage() {
    }

    /**
     * 开始一次调用：清掉本线程上一次的失败，并绑定 tag 供跨线程读取。
     * 必须在 {@code getSpider} 之前调用，否则会读到上一次调用的残留阶段。
     */
    public static void begin(String tag) {
        CURRENT.remove();
        if (tag == null || tag.trim().isEmpty()) {
            TAG.remove();
        } else {
            TAG.set(tag);
            BY_TAG.remove(tag);
        }
    }

    /** 记录一次失败（可被后续更早阶段的失败覆盖，以最后一次写入为准）。 */
    public static void fail(String stage, String detail) {
        Failure f = new Failure(stage, trim(detail));
        CURRENT.set(f);
        String tag = TAG.get();
        if (tag != null) {
            if (BY_TAG.size() > MAX_TAGS) {
                BY_TAG.clear();
            }
            BY_TAG.put(tag, f);
        }
    }

    /** 当前线程最后一次失败；无失败返回 null。 */
    public static Failure current() {
        return CURRENT.get();
    }

    /** 按 tag 取失败（跨线程）；无记录返回 null。 */
    public static Failure forTag(String tag) {
        if (tag == null || tag.trim().isEmpty()) return null;
        return BY_TAG.get(tag);
    }

    /** 单次调用结束后清理 tag 记录，避免误用在下一轮。 */
    public static void clearTag(String tag) {
        if (tag == null || tag.trim().isEmpty()) return;
        BY_TAG.remove(tag);
        if (tag.equals(TAG.get())) {
            TAG.remove();
        }
    }

    /** 全量重置（配置切换 / 加载器清理时调用）。 */
    public static void reset() {
        BY_TAG.clear();
        CURRENT.remove();
        TAG.remove();
    }

    private static String trim(String detail) {
        if (detail == null) return "";
        String s = detail.replace('\n', ' ').replace('\r', ' ').trim();
        return s.length() > 200 ? s.substring(0, 200) + "…" : s;
    }
}
