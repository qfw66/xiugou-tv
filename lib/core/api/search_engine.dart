import 'dart:async';
import 'dart:developer' as developer;
import '../config/models/vod_config.dart';
import 'models/vod_models.dart';
import 'site_api.dart';

/// 单个站点的检索批次（增量搜索用）。
///
/// [completed] / [total] 用于 UI 显示「搜索中 k/N」；单站异常不会中断整条流，
/// 而是发一个 [items] 为空、[error] 非空的批次（与既有「单站失败不影响整体」语义一致）。
class SearchBatch {
  const SearchBatch({
    required this.site,
    required this.items,
    required this.completed,
    required this.total,
    this.error,
  });

  final Site site;
  final List<VodItem> items;
  final int completed;
  final int total;
  final Object? error;
}

/// 搜索结果去重键：站点 + 条目 id + 片名（与既有 `searchAll` 完全一致）。
String searchItemKey(VodItem item) =>
    '${item.siteKey}_${item.id}_${item.name}';

/// 按 [searchItemKey] 去重后追加到 [target]；[seen] 由调用方跨批次持有。
void appendUniqueSearchItems(
  List<VodItem> target,
  Set<String> seen,
  Iterable<VodItem> incoming,
) {
  for (final item in incoming) {
    if (seen.add(searchItemKey(item))) target.add(item);
  }
}

/// 跨站点并发聚合搜索调度引擎
///
/// 站源请求统一经过 [SiteApi]，使 Spider / JS 站源与 CMS 站源走同一条分派
/// 链路。此前的实现直接调用 CMS 客户端，Spider 站源会被当作 CMS 端点请求。
class SearchEngine {
  final SiteApi _siteApi;

  /// 单站检索超时（保持既有 20 秒语义）
  static const Duration siteTimeout = Duration(seconds: 20);

  SearchEngine({SiteApi? siteApi}) : _siteApi = siteApi ?? SiteApi();

  void _log(String message) {
    developer.log(message, name: 'TVBox-Desktop::SearchEngine');
    // ignore: avoid_print
    print('[SearchEngine] $message');
  }

  /// 可检索站源：`searchable != 0` 且 api 非空（与 [searchAll] 同一判据）
  List<Site> _searchableSites(List<Site> sites) =>
      sites.where((s) => s.searchable != 0 && s.api.isNotEmpty).toList();

  /// 逐站增量检索：**任一站点完成即发一批**，不等待最慢站点。
  ///
  /// - 顺序：按完成先后（不保证与站源列表顺序一致）；
  /// - 单站异常：吞掉并发送空批次（`error` 非空），流不中断；
  /// - 空关键词 / 无可检索站源：立即结束，不发起请求；
  /// - 订阅取消：停止发送后续批次（底层请求无法中止，结果丢弃）。
  Stream<SearchBatch> searchAllIncremental(
      List<Site> sites, String keyword) async* {
    final query = keyword.trim();
    if (query.isEmpty) return;

    final targetSites = _searchableSites(sites);
    _log('========== [聚合搜索启动] ==========');
    _log('搜索关键词: "$query", 待检索站源总数: ${targetSites.length}');

    if (targetSites.isEmpty) {
      _log('未找到可搜索的有效站源');
      return;
    }

    final pending = <Site, Future<_SiteSearchOutcome>>{
      for (final site in targetSites) site: _searchSiteOutcome(site, query),
    };

    var completed = 0;
    while (pending.isNotEmpty) {
      final outcome = await Future.any(pending.values);
      pending.remove(outcome.site);
      completed++;
      yield SearchBatch(
        site: outcome.site,
        items: outcome.items,
        completed: completed,
        total: targetSites.length,
        error: outcome.error,
      );
    }
  }

  Future<_SiteSearchOutcome> _searchSiteOutcome(Site site, String query) async {
    try {
      final res =
          await _siteApi.search(site, keyword: query).timeout(siteTimeout);
      // 为每个返回项打上站点标签
      final taggedList = res.list.map((item) {
        return item.copyWith(
          siteKey: site.key,
          siteName: site.name,
          tag: (item.tag != null && item.tag!.isNotEmpty)
              ? item.tag
              : site.name,
        );
      }).toList();
      _log('  -> 站源 [${site.name}] 检索完成: 返回 ${taggedList.length} 条数据');
      return _SiteSearchOutcome(site: site, items: taggedList);
    } catch (e) {
      _log('  -> 站源 [${site.name}] 检索异常: $e');
      return _SiteSearchOutcome(site: site, items: const <VodItem>[], error: e);
    }
  }

  /// 对所有已开启搜索的站点并发检索关键词（一次性返回，供非 UI 调用方使用）
  ///
  /// 实现复用 [searchAllIncremental]，保证与增量路径同一套打标 / 去重 / 超时语义。
  Future<List<VodItem>> searchAll(List<Site> sites, String keyword) async {
    final aggregated = <VodItem>[];
    final seenKeys = <String>{};
    await for (final batch in searchAllIncremental(sites, keyword)) {
      appendUniqueSearchItems(aggregated, seenKeys, batch.items);
    }
    final query = keyword.trim();
    if (query.isNotEmpty) {
      _log('========== [聚合搜索汇总] ==========');
      _log('关键词: "$query", 合并去重后总计获得: ${aggregated.length} 部影片');
    }
    return aggregated;
  }

  /// 当前站源是否可被现有搜索路径检索：`searchable != 0` 且 api 非空。
  ///
  /// 具体能否返回结果由 [SiteApi] 在运行时决定；此处不做端点预判，避免把
  /// 走 Companion 的 Spider 站源误判为不可搜索。
  bool supportsSearch(Site site) =>
      site.searchable != 0 && site.api.isNotEmpty;

  /// 仅检索单个站源（聚合关闭时使用）
  Future<List<VodItem>> searchSite(Site site, String keyword) =>
      searchAll([site], keyword);
}

class _SiteSearchOutcome {
  const _SiteSearchOutcome({
    required this.site,
    required this.items,
    this.error,
  });

  final Site site;
  final List<VodItem> items;
  final Object? error;
}
