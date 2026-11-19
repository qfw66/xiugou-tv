import 'package:flutter/foundation.dart' show setEquals;

/// 搜索显示与聚合开关偏好。
///
/// 持久化于应用数据目录的 `search_preferences.json`（version 1）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（由调用方处理）；
/// 未知取值归一化为默认（海报模式 / 聚合开）。
///
/// 同文件还存分类页的浏览偏好 `filterBarExpanded`（v1.0.5 新增，仍为 version 1：
/// 旧文件缺该字段按默认收起读取，旧版本读到新文件会忽略多出的字段）。
class SearchPreferences {
  static const int formatVersion = 1;

  /// 搜索结果显示方式；默认海报模式（与现状一致）
  final SearchDisplay display;

  /// 聚合搜索开关；默认开启（与现状一致）
  final bool aggregate;

  /// 分类页筛选条进入时是否默认展开；默认收起（筛选行多时会挤占海报区）。
  /// 页面上的展开 / 收起只在本次运行内有效，不改这里。
  final bool filterBarExpanded;

  final Map<String, Set<String>> _sitesByConfig;

  const SearchPreferences({
    this.display = SearchDisplay.poster,
    this.aggregate = true,
    this.filterBarExpanded = false,
  }) : _sitesByConfig = const {};

  const SearchPreferences._(
    this.display,
    this.aggregate,
    this.filterBarExpanded,
    this._sitesByConfig,
  );

  SearchPreferences copyWith({
    SearchDisplay? display,
    bool? aggregate,
    bool? filterBarExpanded,
  }) => SearchPreferences._(
    display ?? this.display,
    aggregate ?? this.aggregate,
    filterBarExpanded ?? this.filterBarExpanded,
    _sitesByConfig,
  );

  /// 按配置身份区分站点 key。未选择过表示全选，空集合表示不请求任何站点。
  Set<String>? aggregateSitesFor(String? configId) => _sitesByConfig[configId];

  SearchPreferences withAggregateSites(String configId, Set<String>? keys) {
    if (setEquals(_sitesByConfig[configId], keys)) return this;
    final next = Map.of(_sitesByConfig);
    if (keys == null) {
      next.remove(configId);
    } else {
      next[configId] = Set.unmodifiable(keys);
    }
    return SearchPreferences._(display, aggregate, filterBarExpanded, next);
  }

  /// 严格解析：结构 / 版本 / 字段类型非法时抛出 [FormatException]；未知显示值归一化为默认。
  static SearchPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('搜索偏好格式无效');
    }
    final rawDisplay = json['display'];
    if (rawDisplay != null && rawDisplay is! String) {
      throw const FormatException('搜索偏好格式无效');
    }
    final rawAggregate = json['aggregate'];
    if (rawAggregate != null && rawAggregate is! bool) {
      throw const FormatException('搜索偏好格式无效');
    }
    final rawFilterBar = json['filterBarExpanded'];
    if (rawFilterBar != null && rawFilterBar is! bool) {
      throw const FormatException('搜索偏好格式无效');
    }
    final rawScopes = json['aggregateSitesByConfig'];
    final scopes = <String, Set<String>>{};
    if (rawScopes != null) {
      if (rawScopes is! Map<String, dynamic>) {
        throw const FormatException('搜索站点范围格式无效');
      }
      for (final entry in rawScopes.entries) {
        final keys = entry.value;
        if (entry.key.isEmpty ||
            keys is! List ||
            keys.any((key) => key is! String)) {
          throw const FormatException('搜索站点范围格式无效');
        }
        scopes[entry.key] = Set.unmodifiable(keys.cast<String>());
      }
    }
    return SearchPreferences._(
      SearchDisplay.tryParse(rawDisplay) ?? SearchDisplay.poster,
      rawAggregate as bool? ?? true,
      rawFilterBar as bool? ?? false,
      scopes,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': formatVersion,
    'display': display.value,
    'aggregate': aggregate,
    'filterBarExpanded': filterBarExpanded,
    if (_sitesByConfig.isNotEmpty)
      'aggregateSitesByConfig': {
        for (final id in _sitesByConfig.keys.toList()..sort())
          id: _sitesByConfig[id]!.toList()..sort(),
      },
  };

  @override
  bool operator ==(Object other) =>
      other is SearchPreferences &&
      other.display == display &&
      other.aggregate == aggregate &&
      other.filterBarExpanded == filterBarExpanded &&
      _sitesByConfig.length == other._sitesByConfig.length &&
      _sitesByConfig.entries.every(
        (entry) => setEquals(entry.value, other._sitesByConfig[entry.key]),
      );

  @override
  int get hashCode => Object.hash(
    display,
    aggregate,
    filterBarExpanded,
    Object.hashAllUnordered(
      _sitesByConfig.entries.map(
        (entry) => Object.hash(entry.key, Object.hashAllUnordered(entry.value)),
      ),
    ),
  );

  @override
  String toString() =>
      'SearchPreferences(display: ${display.value}, aggregate: $aggregate, '
      'filterBarExpanded: $filterBarExpanded)';
}

/// 搜索结果显示方式
enum SearchDisplay {
  /// 海报模式（瀑布流，现状）
  poster('poster'),

  /// 文字列表
  list('list');

  final String value;

  const SearchDisplay(this.value);

  /// 按持久化值解析；未知值返回 null（调用方决定回退）
  static SearchDisplay? tryParse(Object? value) {
    for (final entry in SearchDisplay.values) {
      if (entry.value == value) return entry;
    }
    return null;
  }
}
