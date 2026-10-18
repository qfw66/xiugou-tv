/// 历史记录数量偏好（播放历史保留上限）。
///
/// 持久化于应用数据目录的 `history_preferences.json`（version 1）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（由调用方处理）；
/// 数值超出 [minLimit, maxLimit] 归一化为默认；合法但非档位值保留（界面动态展示，不静默改写）。
class HistoryPreferences {
  static const int formatVersion = 1;

  /// 默认保留条数（与现状一致；与 ConfigRepository.defaultHistoryLimit 同值）
  static const int defaultLimit = 150;

  /// 可配置范围：低于 / 高于该范围的数值视为无效并归一化为默认
  static const int minLimit = 10;
  static const int maxLimit = 9999;

  /// 界面档位（升序）；[defaultLimit] 为默认档
  static const List<int> limitOptions = [30, 50, 100, 150, 200, 300, 500];

  final int limit;

  const HistoryPreferences({this.limit = defaultLimit});

  HistoryPreferences copyWith({int? limit}) => HistoryPreferences(limit: limit ?? this.limit);

  /// 数值归一化：超出 [minLimit, maxLimit] 时回落默认；其余保留原值。
  static int normalizeLimit(int value) =>
      (value < minLimit || value > maxLimit) ? defaultLimit : value;

  /// 严格解析：结构 / 版本 / 字段类型非法时抛出 [FormatException]；数值越界归一化为默认。
  static HistoryPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('历史偏好格式无效');
    }
    final rawLimit = json['limit'];
    if (rawLimit != null && rawLimit is! int) {
      throw const FormatException('历史偏好格式无效');
    }
    return HistoryPreferences(limit: normalizeLimit(rawLimit as int? ?? defaultLimit));
  }

  Map<String, dynamic> toJson() => {'version': formatVersion, 'limit': limit};

  @override
  bool operator ==(Object other) => other is HistoryPreferences && other.limit == limit;

  @override
  int get hashCode => limit.hashCode;

  @override
  String toString() => 'HistoryPreferences(limit: $limit)';
}
