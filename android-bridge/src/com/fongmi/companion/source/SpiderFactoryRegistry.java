package com.fongmi.companion.source;

import com.github.catvod.crawler.Spider;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 按优先级排列的 spider 工厂链：数字小的先问，第一个返回非 null 的胜出。
 *
 * <p>新增一种源类型 = {@link #register} 一个工厂，不改加载器。同优先级按注册顺序。
 */
public final class SpiderFactoryRegistry {

    /** 一个已注册的工厂。 */
    public record Entry(String id, int priority, SpiderFactory factory) {
    }

    private final CopyOnWriteArrayList<Entry> entries = new CopyOnWriteArrayList<>();

    /**
     * 注册工厂。
     *
     * @param id       日志与诊断用的标识（同 id 重复注册会替换旧的）
     * @param priority 越小越先尝试
     */
    public synchronized void register(String id, int priority, SpiderFactory factory) {
        entries.removeIf(e -> e.id().equals(id));
        List<Entry> next = new ArrayList<>(entries);
        next.add(new Entry(id, priority, factory));
        // List.sort 是稳定排序：同优先级保持注册顺序
        next.sort(Comparator.comparingInt(Entry::priority));
        entries.clear();
        entries.addAll(next);
    }

    /** 当前工厂链（按尝试顺序）。 */
    public List<Entry> entries() {
        return new ArrayList<>(entries);
    }

    /** 依次尝试；全部返回 null 时返回 null。 */
    public Spider create(SpiderRequest request) {
        for (Entry entry : entries) {
            try {
                Spider spider = entry.factory().tryCreate(request);
                if (spider != null) {
                    System.out.println("[SpiderFactory] " + entry.id() + " 命中: api=" + request.api()
                            + " site=" + request.siteKey());
                    return spider;
                }
            } catch (Throwable t) {
                System.err.println("[SpiderFactory] " + entry.id() + " 失败，继续下一个: api=" + request.api()
                        + " " + t);
            }
        }
        return null;
    }
}
