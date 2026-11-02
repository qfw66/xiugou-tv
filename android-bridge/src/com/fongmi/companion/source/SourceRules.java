package com.fongmi.companion.source;

import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

/**
 * 站点执行规则：通用加载链覆盖不到的例外，全部是数据（见 {@code source-rules.properties}）。
 *
 * <p>两层来源，后者覆盖前者：
 * <ol>
 *   <li>jar 内 {@code /source-rules.properties}（随版本发布）；</li>
 *   <li>{@code <用户目录>/source-rules.properties}（用户追加/覆盖，不需重新打包）。</li>
 * </ol>
 * 规则只在首次使用时装载一次；新增例外只改数据，不改加载器代码。
 */
public final class SourceRules {

    static final String RESOURCE = "/source-rules.properties";
    static final String FILE_NAME = "source-rules.properties";

    private final Map<String, String> aliases;
    private final Map<String, String> defaultExt;
    private final Set<String> blocked;

    SourceRules(Map<String, String> aliases, Map<String, String> defaultExt, Set<String> blocked) {
        this.aliases = Collections.unmodifiableMap(aliases);
        this.defaultExt = Collections.unmodifiableMap(defaultExt);
        this.blocked = Collections.unmodifiableSet(blocked);
    }

    /**
     * 装载内置规则并叠加用户目录下的覆盖文件。
     *
     * @param userDir 用户规则所在目录；可为 null（只用内置）
     */
    public static SourceRules load(File userDir) {
        Properties merged = new Properties();
        try (InputStream in = SourceRules.class.getResourceAsStream(RESOURCE)) {
            if (in == null) {
                // 缺内置规则意味着打包漏了资源：别名/拦截全部失效，必须显眼地报出来
                System.err.println("[SourceRules] jar 内缺 " + RESOURCE + "，内置规则不可用（检查打包是否复制 android-bridge/resources）");
            } else {
                merged.load(new InputStreamReader(in, StandardCharsets.UTF_8));
            }
        } catch (Throwable t) {
            System.err.println("[SourceRules] 内置规则读取失败: " + t);
        }
        File user = userDir == null ? null : new File(userDir, FILE_NAME);
        if (user != null && user.isFile()) {
            try (InputStream in = Files.newInputStream(user.toPath())) {
                Properties p = new Properties();
                p.load(new InputStreamReader(in, StandardCharsets.UTF_8));
                // blocked 是崩溃保护，只能追加不能被覆盖掉：用户写 blocked=x 不应悄悄放行内置拦截的载荷
                String userBlocked = p.getProperty("blocked");
                String builtinBlocked = merged.getProperty("blocked");
                if (userBlocked != null && builtinBlocked != null) {
                    p.setProperty("blocked", builtinBlocked + "," + userBlocked);
                }
                merged.putAll(p);
                System.out.println("[SourceRules] 已叠加用户规则 " + user.getAbsolutePath() + "（" + p.size() + " 条）");
            } catch (Throwable t) {
                System.err.println("[SourceRules] 用户规则读取失败，忽略: " + user + " " + t);
            }
        }
        return parse(merged);
    }

    static SourceRules parse(Properties p) {
        Map<String, String> aliases = new HashMap<>();
        Map<String, String> defaultExt = new HashMap<>();
        Set<String> blocked = new HashSet<>();
        for (String key : p.stringPropertyNames()) {
            String value = p.getProperty(key, "").trim();
            if (key.startsWith("alias.")) {
                if (!value.isEmpty()) aliases.put(key.substring(6).toLowerCase(Locale.ROOT), value);
            } else if (key.startsWith("default.ext.")) {
                if (!value.isEmpty()) defaultExt.put(key.substring(12), value);
            } else if ("blocked".equals(key)) {
                for (String api : value.split("[,;\\s]+")) {
                    if (!api.isEmpty()) blocked.add(api.toLowerCase(Locale.ROOT));
                }
            }
        }
        return new SourceRules(aliases, defaultExt, blocked);
    }

    /** 内置实现别名（按小写 api 匹配）；无则 null。 */
    public String alias(String cleanApi) {
        return cleanApi == null ? null : aliases.get(cleanApi.toLowerCase(Locale.ROOT));
    }

    /** 配置缺 ext 时的默认值（按 api 原样匹配）；无则 null。 */
    public String defaultExt(String cleanApi) {
        return cleanApi == null ? null : defaultExt.get(cleanApi);
    }

    /** 该 api 是否必须在加载前拒绝。 */
    public boolean isBlocked(String cleanApi) {
        return cleanApi != null && blocked.contains(cleanApi.toLowerCase(Locale.ROOT));
    }

    @Override
    public String toString() {
        return "SourceRules{alias=" + aliases.size() + ", defaultExt=" + defaultExt.size()
                + ", blocked=" + blocked.size() + "}";
    }
}
