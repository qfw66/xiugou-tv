package com.fongmi.companion;

import org.jsoup.Jsoup;
import org.jsoup.nodes.Document;
import org.jsoup.nodes.Element;
import org.jsoup.select.Elements;

import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** DOM surface used by the GM user-script runtime. */
final class GmHtml {
    private final Document document;
    private final IdentityHashMap<Element, Integer> ids = new IdentityHashMap<>();
    private final Map<Integer, Element> elements = new LinkedHashMap<>();
    private int nextId = 1;

    GmHtml(String html) {
        document = Jsoup.parse(html == null ? "" : html);
        id(document.body());
    }

    String select(String selector) {
        return encode(document.select(selector));
    }

    String body() {
        return JsonCodec.stringify(snapshot(document.body()));
    }

    String find(int id, String selector) {
        Element root = element(id);
        if (root == null) return "[]";
        Elements selected = root.select(selector);
        selected.remove(root);
        return encode(selected);
    }

    String children(int id, String selector) {
        Element root = element(id);
        if (root == null) return "[]";
        Elements selected = new Elements();
        for (Element child : root.children()) {
            if (selector == null || selector.isBlank() || child.is(selector)) selected.add(child);
        }
        return encode(selected);
    }

    String adjacent(int id, String selector, int direction) {
        Element current = element(id);
        if (current == null) return "[]";
        Element sibling = direction < 0 ? current.previousElementSibling() : current.nextElementSibling();
        if (sibling == null || selector != null && !selector.isBlank() && !sibling.is(selector)) return "[]";
        return JsonCodec.stringify(List.of(snapshot(sibling)));
    }

    String parent(int id, String selector) {
        Element current = element(id);
        Element parent = current == null ? null : current.parent();
        if (parent == null || parent == document || selector != null && !selector.isBlank() && !parent.is(selector)) return "[]";
        return JsonCodec.stringify(List.of(snapshot(parent)));
    }

    String closest(int id, String selector) {
        for (Element current = element(id); current != null && current != document; current = current.parent()) {
            if (current.is(selector)) return JsonCodec.stringify(List.of(snapshot(current)));
        }
        return "[]";
    }

    boolean matches(int id, String selector) {
        Element current = element(id);
        return current != null && current.is(selector);
    }

    String snapshot(int id) {
        Element current = element(id);
        return current == null ? "{}" : JsonCodec.stringify(snapshot(current));
    }

    void remove(int id) {
        Element current = element(id);
        if (current != null) current.remove();
    }

    private Element element(int id) {
        return elements.get(id);
    }

    private int id(Element element) {
        Integer existing = ids.get(element);
        if (existing != null) return existing;
        int created = nextId++;
        ids.put(element, created);
        elements.put(created, element);
        return created;
    }

    private String encode(Elements selected) {
        List<Object> result = new ArrayList<>(selected.size());
        for (Element element : selected) result.add(snapshot(element));
        return JsonCodec.stringify(result);
    }

    private Map<String, Object> snapshot(Element element) {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("id", id(element));
        value.put("tagName", element.tagName());
        value.put("outerHtml", element.outerHtml());
        value.put("html", element.html());
        value.put("text", element.tagName().equals("script") || element.tagName().equals("style")
                ? element.data() : element.wholeText());
        Map<String, String> attrs = new LinkedHashMap<>();
        element.attributes().forEach(attribute -> attrs.put(attribute.getKey(), attribute.getValue()));
        value.put("attrs", attrs);
        return value;
    }
}
