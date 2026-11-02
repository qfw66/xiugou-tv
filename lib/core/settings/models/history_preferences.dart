/// 播放历史偏好：保留上限 + 无痕浏览（§14）。
///
/// 持久化于应用数据目录的 `history_preferences.json`（写出 version 2；
/// 读取兼容 version 1，旧文件没有无痕字段，按关闭处理）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（由调用方处理）；
/// 数值超出 [minLimit, maxLimit] 归一化为默认；合法但非档位值保留（界面动态展示，不静默改写）。
class HistoryPreferences {
  static const int formatVersion = 2;

  /// 仍可读取的旧格式版本（无 `incognito` 字段）
  static const int legacyFormatVersion = 1;

  /// 默认保留条数（与现状一致；与 ConfigRepository.defaultHistoryLimit 同值）
  static const int defaultLimit = 150;

  /// 可配置范围：低于 / 高于该范围的数值视为无效并归一化为默认
  static const int minLimit = 10;
  static const int maxLimit = 9999;

  /// 界面档位（升序）；[defaultLimit] 为默认档
  static const List<int> limitOptions = [30, 50, 100, 150, 200, 300, 500];

  final int limit;

  /// 无痕浏览：开启后不新增播放历史、不更新续播进度与线路；已有记录照常可看可续播。
  final bool incognito;

  const HistoryPreferences({this.limit = defaultLimit, this.incognito = false});

  HistoryPreferences copyWith({int? limit, bool? incognito}) => HistoryPreferences(
        limit: limit ?? this.limit,
        incognito: incognito ?? this.incognito,
      );

  /// 数值归一化：超出 [minLimit, maxLimit] 时回落默认；其余保留原值。
  static int normalizeLimit(int value) =>
      (value < minLimit || value > maxLimit) ? defaultLimit : value;

  /// 严格解析：结构 / 版本 / 字段类型非法时抛出 [FormatException]；数值越界归一化为默认。
  static HistoryPreferences fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != formatVersion && version != legacyFormatVersion) {
      throw const FormatException('历史偏好格式无效');
    }
    final rawLimit = json['limit'];
    if (rawLimit != null && rawLimit is! int) {
      throw const FormatException('历史偏好格式无效');
    }
    // v1 没有该字段：一律按关闭读入；v2 字段类型非法视为损坏。
    final rawIncognito = version == formatVersion ? json['incognito'] : null;
    if (rawIncognito != null && rawIncognito is! bool) {
      throw const FormatException('历史偏好格式无效');
    }
    return HistoryPreferences(
      limit: normalizeLimit(rawLimit as int? ?? defaultLimit),
      incognito: rawIncognito as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() =>
      {'version': formatVersion, 'limit': limit, 'incognito': incognito};

  @override
  bool operator ==(Object other) =>
      other is HistoryPreferences && other.limit == limit && other.incognito == incognito;

  @override
  int get hashCode => Object.hash(limit, incognito);

  @override
  String toString() => 'HistoryPreferences(limit: $limit, incognito: $incognito)';
}
