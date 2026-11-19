package com.fongmi.companion;

import org.jsoup.Jsoup;
import org.jsoup.nodes.Document;
import org.jsoup.nodes.Element;
import org.jsoup.select.Elements;

import java.net.URI;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * drpy 规则语法的 HTML 解析（宿主函数 pdfh / pdfa / pdfl / pd / joinUrl），语义对齐 TVBox QuickJS 宿主。
 *
 * <p>规则形如 {@code 选择器&&选择器&&选项}：
 * <ul>
 *   <li>选择器逐段在上一段结果里继续选；pdfh 时没写下标的段默认取第一个（{@code :eq(0)}），
 *       pdfa 时最后一段保留全部；{@code :eq(-1)} 从末尾数。</li>
 *   <li>{@code 选择器--排除1--排除2}：在结果的副本上移除匹配的子节点。</li>
 *   <li>选项：{@code Text}、{@code Html}、属性名；{@code a||b} 依次尝试取第一个非空；省略时返回 outerHtml。</li>
 *   <li>pd 额外按 baseUrl 补全 URL 类属性（href / src / data-xxx / style 里的 url()）。</li>
 * </ul>
 * 非线程安全：同一实例只在一个爬虫上下文里串行使用（缓存最近一次解析的文档）。
 */
public final class DrpyParser {
    private static final Pattern STYLE_URL = Pattern.compile("url\\((.*?)\\)", Pattern.DOTALL);
    private static final Pattern NO_ADD_INDEX = Pattern.compile(
            ":eq|:lt|:gt|:first|:last|:not|:even|:odd|:has|:contains|:matches|:empty|^body$|^#");
    private static final Pattern URL_JOIN_ATTR = Pattern.compile(
            "(url|src|href|-original|-src|-play|-url|style)$|^(data-|url-|src-)", Pattern.CASE_INSENSITIVE);
    private static final Pattern SPECIAL_URL = Pattern.compile("^(ftp|magnet|thunder|ws):", Pattern.CASE_INSENSITIVE);

    private String pdfhHtml;
    private Document pdfhDoc;
    private String pdfaHtml;
    private Document pdfaDoc;

    public String pdfh(String html, String rule) {
        return parseDomForUrl(html, rule, "");
    }

    public String pd(String html, String rule, String baseUrl) {
        return parseDomForUrl(html, rule, baseUrl == null ? "" : baseUrl);
    }

    public List<String> pdfa(String html, String rule) {
        if (html == null || rule == null) return new ArrayList<>();
        if (!html.equals(pdfaHtml)) {
            pdfaHtml = html;
            pdfaDoc = Jsoup.parse(html);
        }
        Elements ret = select(pdfaDoc, hikerToJq(rule, false));
        List<String> out = new ArrayList<>();
        if (ret == null) return out;
        for (Element it : ret) out.add(it.outerHtml());
        return out;
    }

    /** 列表每项输出 {@code 文本$链接}（选集列表用）。 */
    public List<String> pdfl(String html, String rule, String textRule, String urlRule, String urlKey) {
        List<String> out = new ArrayList<>();
        if (html == null || rule == null) return out;
        Elements ret = select(Jsoup.parse(html), hikerToJq(rule, false));
        if (ret == null) return out;
        for (Element it : ret) {
            String item = it.outerHtml();
            out.add(parseDomForUrl(item, textRule, "").trim() + '$' + parseDomForUrl(item, urlRule, urlKey == null ? "" : urlKey));
        }
        return out;
    }

    /** 相对地址拼接，去掉 #fragment；parent 为空时原样返回 child。 */
    public String joinUrl(String parent, String child) {
        if (parent == null || parent.isEmpty()) return child == null ? "" : child;
        if (child == null) child = "";
        String joined = parent;
        try {
            joined = URI.create(DrpyHost.asciiUrl(parent)).resolve(DrpyHost.asciiUrl(child)).toString();
        } catch (IllegalArgumentException e) {
            try {
                joined = new java.net.URL(new java.net.URL(parent), child).toExternalForm();
            } catch (java.net.MalformedURLException ignored) {
                // 保持 parent
            }
        }
        int hash = joined.indexOf('#');
        return hash >= 0 ? joined.substring(0, hash) : joined;
    }

    // ---------------------------------------------------------------- 内部

    private String parseDomForUrl(String html, String rule, String addUrl) {
        if (html == null || rule == null) return "";
        if (!html.equals(pdfhHtml)) {
            pdfhHtml = html;
            pdfhDoc = Jsoup.parse(html);
        }
        Document doc = pdfhDoc;
        if (rule.equals("body&&Text") || rule.equals("Text")) return doc.text();
        if (rule.equals("body&&Html") || rule.equals("Html")) return doc.html();
        String option = "";
        if (rule.contains("&&")) {
            String[] parts = rule.split("&&");
            option = parts[parts.length - 1];
            rule = String.join("&&", Arrays.copyOf(parts, parts.length - 1));
        }
        Elements ret = select(doc, hikerToJq(rule, true));
        if (ret == null) return "";
        if (option.isEmpty()) return ret.outerHtml();
        String result = "";
        for (String opt : option.split("\\|\\|")) {
            result = optionValue(ret, opt, addUrl);
            if (!result.isEmpty()) break;
        }
        return result;
    }

    private String optionValue(Elements ret, String option, String addUrl) {
        if (option.equals("Text")) return ret.text();
        if (option.equals("Html")) return ret.html();
        String result = ret.attr(option);
        if (option.toLowerCase(Locale.ROOT).contains("style") && result.contains("url(")) {
            Matcher m = STYLE_URL.matcher(result);
            if (m.find()) result = m.group(1);
            result = result.replaceAll("^['\"](.*)['\"]$", "$1");
        }
        if (!result.isEmpty() && !addUrl.isEmpty()
                && URL_JOIN_ATTR.matcher(option).find() && !SPECIAL_URL.matcher(result).find()) {
            result = result.contains("http") ? result.substring(result.indexOf("http")) : joinUrl(addUrl, result);
        }
        return result;
    }

    /** 逐段选择；任一段为空返回 null。 */
    private static Elements select(Document doc, String jq) {
        Elements ret = null;
        for (String part : jq.split(" ")) {
            if (part.isEmpty()) continue;
            ret = parseOneRule(doc, part, ret);
            if (ret.isEmpty()) return null;
        }
        return ret;
    }

    /** 把 {@code a&&b&&c} 转成空格分隔的逐段选择器，并按 pdfh / pdfa 语义补 {@code :eq(0)}。 */
    private static String hikerToJq(String parse, boolean first) {
        if (!parse.contains("&&")) {
            String[] split = parse.split(" ");
            if (!NO_ADD_INDEX.matcher(split[split.length - 1]).find() && first) parse = parse + ":eq(0)";
            return parse;
        }
        String[] parses = parse.split("&&");
        List<String> out = new ArrayList<>();
        for (int i = 0; i < parses.length; i++) {
            String[] pss = parses[i].split(" ");
            if (NO_ADD_INDEX.matcher(pss[pss.length - 1]).find()) {
                out.add(parses[i]);
            } else if (!first && i >= parses.length - 1) {
                out.add(parses[i]);
            } else {
                out.add(parses[i] + ":eq(0)");
            }
        }
        return String.join(" ", out);
    }

    private static Elements parseOneRule(Document doc, String parse, Elements prev) {
        String rule = parse;
        int index = 0;
        List<String> excludes = new ArrayList<>();
        boolean indexed = parse.contains(":eq");
        if (indexed) {
            rule = parse.split(":")[0];
            String pos = parse.split(":")[1];
            if (rule.contains("--")) {
                String[] rules = rule.split("--");
                excludes.addAll(Arrays.asList(rules).subList(1, rules.length));
                rule = rules[0];
            } else if (pos.contains("--")) {
                String[] rules = pos.split("--");
                excludes.addAll(Arrays.asList(rules).subList(1, rules.length));
                pos = rules[0];
            }
            try {
                index = Integer.parseInt(pos.replace("eq(", "").replace(")", "").trim());
            } catch (NumberFormatException e) {
                index = 0;
            }
        } else if (parse.contains("--")) {
            String[] rules = parse.split("--");
            excludes.addAll(Arrays.asList(rules).subList(1, rules.length));
            rule = rules[0];
        }
        Elements ret;
        try {
            ret = prev == null ? doc.select(rule) : prev.select(rule);
        } catch (RuntimeException invalidSelector) {
            return new Elements();
        }
        if (indexed) {
            int at = index < 0 ? ret.size() + index : index;
            ret = at >= 0 && at < ret.size() ? new Elements(ret.get(at)) : new Elements();
        }
        if (!excludes.isEmpty() && !ret.isEmpty()) {
            Elements copy = new Elements();
            for (Element e : ret) copy.add(e.clone());
            for (String exclude : excludes) {
                try {
                    copy.select(exclude).remove();
                } catch (RuntimeException ignored) {
                    // 非法排除选择器忽略
                }
            }
            ret = copy;
        }
        return ret;
    }
}
