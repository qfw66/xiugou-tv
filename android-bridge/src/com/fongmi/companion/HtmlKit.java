package com.fongmi.companion;

import org.graalvm.polyglot.HostAccess;
import org.jsoup.Jsoup;
import org.jsoup.nodes.Document;
import org.jsoup.nodes.Element;
import org.jsoup.select.Elements;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Minimal HTML bridge used by the JavaScript source adapter. */
public final class HtmlKit {
    private HtmlKit() {}

    @HostAccess.Export
    public static String select(String html, String selector) {
        Document document = Jsoup.parse(html == null ? "" : html);
        return encode(document.select(selector == null ? "" : selector));
    }

    @HostAccess.Export
    public static String find(String nodeJson, String selector) {
        ElementNode node = ElementNode.fromJson(nodeJson);
        if (node == null) return "[]";
        Document document = Jsoup.parse(node.outerHtml);
        return encode(document.select(selector == null ? "" : selector));
    }

    private static String encode(Element element) {
        if (element == null) return "{}";
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("outerHtml", element.outerHtml());
        value.put("html", element.html());
        value.put("text", element.text());
        Map<String, String> attrs = new LinkedHashMap<>();
        element.attributes().forEach(attribute -> attrs.put(attribute.getKey(), attribute.getValue()));
        value.put("attrs", attrs);
        return JsonCodec.stringify(value);
    }

    private static String encode(Elements elements) {
        List<Object> result = new ArrayList<>();
        for (Element element : elements) result.add(JsonCodec.parse(encode(element)));
        return JsonCodec.stringify(result);
    }

    private static final class ElementNode {
        final String outerHtml;

        private ElementNode(String outerHtml) { this.outerHtml = outerHtml; }

        @SuppressWarnings("unchecked")
        static ElementNode fromJson(String json) {
            Object value = JsonCodec.parse(json);
            if (!(value instanceof Map)) return null;
            Object html = ((Map<String, Object>) value).get("outerHtml");
            return new ElementNode(html == null ? "" : String.valueOf(html));
        }
    }
}
