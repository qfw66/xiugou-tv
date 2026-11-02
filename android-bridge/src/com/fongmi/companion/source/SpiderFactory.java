package com.fongmi.companion.source;

import com.github.catvod.crawler.Spider;

/**
 * 一类源的 spider 工厂。
 *
 * <p>契约：返回 {@code null} 表示「不归我管 / 我这一层没找到」，注册表继续问下一个工厂；
 * 抛异常等同于 {@code null}（由注册表记录后继续），所以一个坏工厂不会拖垮整条链。
 * 返回的实例尚未 {@code init}，初始化由调用方统一完成。
 */
@FunctionalInterface
public interface SpiderFactory {

    Spider tryCreate(SpiderRequest request) throws Exception;
}
