/// 搜索显示与聚合开关偏好。
///
/// 持久化于应用数据目录的 `search_preferences.json`（version 1）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（由调用方处理）；
/// 未知取值归一化为默认（海报模式 / 聚合开）。
class SearchPreferences {
  static const int formatVersion = 1;

  /// 搜索结果显示方式；默认海报模式（与现状一致）
  final SearchDisplay display;

  /// 聚合搜索开关；默认开启（与现状一致）
  final bool aggregate;

  const SearchPreferences({this.display = SearchDisplay.poster, this.aggregate = true});

  SearchPreferences copyWith({SearchDisplay? display, bool? aggregate}) => SearchPreferences(
        display: display ?? this.display,
        aggregate: aggregate ?? this.aggregate,
      );

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
    return SearchPreferences(
      display: SearchDisplay.tryParse(rawDisplay) ?? SearchDisplay.poster,
      aggregate: rawAggregate as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'display': display.value,
        'aggregate': aggregate,
      };

  @override
  bool operator ==(Object other) =>
      other is SearchPreferences && other.display == display && other.aggregate == aggregate;

  @override
  int get hashCode => Object.hash(display, aggregate);

  @override
  String toString() => 'SearchPreferences(display: ${display.value}, aggregate: $aggregate)';
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
