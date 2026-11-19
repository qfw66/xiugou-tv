package com.fongmi.companion;

import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderApi;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;

/**
 * init 之后注入 {@link SpiderApi}（对齐手机端分支宿主的 {@code initApi} 调用）。
 *
 * <p>包装型爬虫（如 HBPQ 内部反射创建 XBPQ 并存进字段）不会转发 {@code initApi}，
 * 内层爬虫拿不到回调就在每次取列表时空指针并返回空串。因此这里额外向一层实例字段里的
 * {@link Spider} 注入。任何异常只记日志，不影响爬虫本身可用。
 */
public final class SpiderApiBinder {
    private SpiderApiBinder() {
    }

    public static void bind(Spider spider) {
        if (spider == null) return;
        SpiderApi api = SpiderApi.get();
        call(spider, api);
        for (Class<?> type = spider.getClass(); type != null && type != Spider.class && type != Object.class;
                type = type.getSuperclass()) {
            for (Field field : type.getDeclaredFields()) {
                if (Modifier.isStatic(field.getModifiers()) || field.getType().isPrimitive()) continue;
                try {
                    field.setAccessible(true);
                    Object value = field.get(spider);
                    if (value instanceof Spider && value != spider) call((Spider) value, api);
                } catch (Throwable ignored) {
                    // 模块封装或安全限制读不到的字段直接跳过
                }
            }
        }
    }

    private static void call(Spider spider, SpiderApi api) {
        try {
            spider.initApi(api);
        } catch (Throwable t) {
            System.err.println("[SpiderApiBinder] initApi 失败（忽略）: " + spider.getClass().getName() + ": " + t);
        }
    }
}
