import '../../../core/api/models/vod_models.dart';

/// 搜索结果按站点归组后的一个站点条目
class SearchSiteGroup {
  /// 稳定的分组键：`key:<siteKey>` / `name:<siteName>` / `unknown`
  final String key;

  /// 展示用站点名：`siteName` → `siteKey` → 「未知来源」
  final String name;

  /// 该站点在去重后结果中的条目数
  final int count;

  const SearchSiteGroup({
    required this.key,
    required this.name,
    required this.count,
  });
}

String _trimmed(String? value) => value?.trim() ?? '';

/// 搜索结果条目的站点分组键。
///
/// 优先使用 `siteKey`（同名站源不会合并）；缺失时退回 `siteName`；都没有时
/// 归入 `unknown`。前缀避免与站源 key 的字面值碰撞。
String searchSiteGroupKey(VodItem item) {
  final siteKey = _trimmed(item.siteKey);
  if (siteKey.isNotEmpty) return 'key:$siteKey';
  final siteName = _trimmed(item.siteName);
  if (siteName.isNotEmpty) return 'name:$siteName';
  return 'unknown';
}

/// 站点分组条目的展示名。
String searchSiteGroupName(VodItem item) {
  final siteName = _trimmed(item.siteName);
  if (siteName.isNotEmpty) return siteName;
  final siteKey = _trimmed(item.siteKey);
  return siteKey.isNotEmpty ? siteKey : '未知来源';
}

/// 将搜索结果按站点归组：数量降序，数量相同按首次出现顺序。
///
/// 只依据实际条目归组，因此 0 命中 / 失败 / 超时的站点不会出现在结果中。
/// Dart 的 `List.sort` 不保证稳定排序，这里显式记录首次出现下标参与比较。
List<SearchSiteGroup> groupSearchResultsBySite(List<VodItem> items) {
  final builders = <String, _GroupBuilder>{};
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    final key = searchSiteGroupKey(item);
    final existing = builders[key];
    if (existing == null) {
      builders[key] = _GroupBuilder(
        key: key,
        name: searchSiteGroupName(item),
        firstIndex: index,
      );
    } else {
      existing.count++;
    }
  }

  final ordered = builders.values.toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.firstIndex.compareTo(b.firstIndex);
    });

  return [
    for (final builder in ordered)
      SearchSiteGroup(
        key: builder.key,
        name: builder.name,
        count: builder.count,
      ),
  ];
}

/// 按分组键过滤搜索结果；[groupKey] 为 null 时原样返回全部条目。
List<VodItem> filterSearchResultsBySite(
  List<VodItem> items,
  String? groupKey,
) {
  if (groupKey == null) return items;
  return [
    for (final item in items)
      if (searchSiteGroupKey(item) == groupKey) item,
  ];
}

class _GroupBuilder {
  _GroupBuilder({
    required this.key,
    required this.name,
    required this.firstIndex,
  });

  final String key;
  final String name;
  final int firstIndex;
  int count = 1;
}
