package com.github.catvod.bean;

import java.util.*;

public class Result {
    private List<Class> classes;
    private List<Vod> list;
    private Map<String, List<Filter>> filters;
    private String url;
    private int parse = 0;
    private int jx = 0;
    private Integer page;
    private Integer pagecount;
    private Integer limit;
    private Integer total;
    private List<Sub> subs;
    private String msg;

    public static Result get() {
        return new Result();
    }

    public static String string(List<Class> classes, List<Vod> list) {
        return get().classes(classes).vod(list).string();
    }

    public static String string(List<Class> classes, Map<String, List<Filter>> filters) {
        return get().classes(classes).filters(filters).string();
    }

    public static String string(List<?> list) {
        if (list == null || list.isEmpty()) return "{\"list\":[]}";
        if (list.get(0) instanceof Vod) {
            @SuppressWarnings("unchecked")
            List<Vod> vods = (List<Vod>) list;
            return get().vod(vods).string();
        }
        if (list.get(0) instanceof Class) {
            @SuppressWarnings("unchecked")
            List<Class> cls = (List<Class>) list;
            return get().classes(cls).string();
        }
        return "{\"list\":[]}";
    }

    public static String string(Vod item) {
        return get().vod(Collections.singletonList(item)).string();
    }

    public Result classes(List<Class> classes) {
        this.classes = classes;
        return this;
    }

    public Result vod(List<Vod> list) {
        this.list = list;
        return this;
    }

    public Result filters(Map<String, List<Filter>> filters) {
        this.filters = filters;
        return this;
    }

    public Result url(String url) {
        this.url = url;
        return this;
    }

    public Result parse() {
        this.parse = 1;
        return this;
    }

    public Result parse(int parse) {
        this.parse = parse;
        return this;
    }

    public Result jx() {
        this.jx = 1;
        return this;
    }

    public Result page(int page, int pagecount, int limit, int total) {
        this.page = page;
        this.pagecount = pagecount;
        this.limit = limit;
        this.total = total;
        return this;
    }

    public Result subs(List<Sub> subs) {
        this.subs = subs;
        return this;
    }

    public Result msg(String msg) {
        this.msg = msg;
        return this;
    }

    public String string() {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;

        if (classes != null) {
            sb.append("\"class\":[");
            for (int i = 0; i < classes.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(classes.get(i).toJson());
            }
            sb.append("]");
            first = false;
        }

        if (list != null) {
            if (!first) sb.append(",");
            sb.append("\"list\":[");
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(list.get(i).toJson());
            }
            sb.append("]");
            first = false;
        }

        if (filters != null) {
            if (!first) sb.append(",");
            sb.append("\"filters\":{");
            int fi = 0;
            for (Map.Entry<String, List<Filter>> entry : filters.entrySet()) {
                if (fi > 0) sb.append(",");
                sb.append("\"").append(escape(entry.getKey())).append("\":[");
                List<Filter> fList = entry.getValue();
                if (fList != null) {
                    for (int j = 0; j < fList.size(); j++) {
                        if (j > 0) sb.append(",");
                        sb.append(fList.get(j).toJson());
                    }
                }
                sb.append("]");
                fi++;
            }
            sb.append("}");
            first = false;
        }

        if (url != null) {
            if (!first) sb.append(",");
            sb.append("\"url\":\"").append(escape(url)).append("\"");
            first = false;
        }

        if (parse > 0) {
            if (!first) sb.append(",");
            sb.append("\"parse\":").append(parse);
            first = false;
        }

        if (jx > 0) {
            if (!first) sb.append(",");
            sb.append("\"jx\":").append(jx);
            first = false;
        }

        if (page != null) {
            if (!first) sb.append(",");
            sb.append("\"page\":").append(page);
            sb.append(",\"pagecount\":").append(pagecount != null ? pagecount : page);
            sb.append(",\"limit\":").append(limit != null ? limit : 20);
            sb.append(",\"total\":").append(total != null ? total : (list != null ? list.size() : 0));
            first = false;
        }

        if (subs != null && !subs.isEmpty()) {
            if (!first) sb.append(",");
            sb.append("\"subs\":[");
            for (int i = 0; i < subs.size(); i++) {
                if (i > 0) sb.append(",");
                sb.append(subs.get(i).toJson());
            }
            sb.append("]");
            first = false;
        }

        if (msg != null) {
            if (!first) sb.append(",");
            sb.append("\"msg\":\"").append(escape(msg)).append("\"");
        }

        sb.append("}");
        return sb.toString();
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }
}
