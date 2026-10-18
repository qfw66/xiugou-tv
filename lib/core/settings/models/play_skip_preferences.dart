/// 片头 / 片尾跳过偏好（按影片维度共享，跨集继承）。
///
/// 持久化于应用数据目录的 `play_skip_preferences.json`（version 1）。
/// 语义对齐上游 TVBox：`openingMs` 为**从头起跳过的绝对毫秒**，
/// `endingMs` 为**距片尾的尾部偏移毫秒**（`duration - endingMs` 为片尾起点）。
///
/// 读取规则：版本 / 顶层结构非法视为损坏并抛出 [FormatException]（调用方保留原文件）；
/// 单条记录非法则丢弃该条（不拖垮整个文件）。
class PlaySkipEntry {
  /// 允许的最大时间点（24h）：超出视为无效并归零。
  static const int maxMs = 24 * 60 * 60 * 1000;

  final int openingMs;
  final int endingMs;

  /// 最近一次修改时间（用于超出上限时淘汰最旧记录）。
  final int updatedAt;

  const PlaySkipEntry({
    this.openingMs = 0,
    this.endingMs = 0,
    this.updatedAt = 0,
  });

  bool get isEmpty => openingMs <= 0 && endingMs <= 0;

  static int normalize(int value) => (value < 0 || value > maxMs) ? 0 : value;

  PlaySkipEntry copyWith({int? openingMs, int? endingMs, int? updatedAt}) =>
      PlaySkipEntry(
        openingMs: normalize(openingMs ?? this.openingMs),
        endingMs: normalize(endingMs ?? this.endingMs),
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 单条解析：非法返回 null（调用方丢弃该条）。
  static PlaySkipEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final opening = raw['openingMs'];
    final ending = raw['endingMs'];
    final updated = raw['updatedAt'];
    if (opening != null && opening is! int) return null;
    if (ending != null && ending is! int) return null;
    if (updated != null && updated is! int) return null;
    return PlaySkipEntry(
      openingMs: normalize(opening as int? ?? 0),
      endingMs: normalize(ending as int? ?? 0),
      updatedAt: updated as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'openingMs': openingMs,
        'endingMs': endingMs,
        'updatedAt': updatedAt,
      };

  @override
  bool operator ==(Object other) =>
      other is PlaySkipEntry &&
      other.openingMs == openingMs &&
      other.endingMs == endingMs &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(openingMs, endingMs, updatedAt);

  @override
  String toString() =>
      'PlaySkipEntry(openingMs: $openingMs, endingMs: $endingMs)';
}

class PlaySkipPreferences {
  static const int formatVersion = 1;

  /// 最多保留的影片条数，超出按 [PlaySkipEntry.updatedAt] 淘汰最旧。
  static const int maxEntries = 500;

  /// 总开关（默认开启）：关闭后既不起播跳过片头，也不在片尾点切集。
  final bool enabled;

  /// `vodId -> 时间点`
  final Map<String, PlaySkipEntry> items;

  const PlaySkipPreferences({this.enabled = true, this.items = const {}});

  PlaySkipEntry? entryFor(String vodId) => items[vodId];

  /// 写入 / 覆盖某影片的时间点；空值等同于移除；超出上限时淘汰最旧。
  PlaySkipPreferences upsert(String vodId, PlaySkipEntry entry) {
    final next = Map<String, PlaySkipEntry>.from(items);
    if (entry.isEmpty) {
      next.remove(vodId);
    } else {
      next[vodId] = entry;
    }
    if (next.length > maxEntries) {
      final ordered = next.entries.toList()
        ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
      next
        ..clear()
        ..addEntries(ordered.take(maxEntries));
    }
    return PlaySkipPreferences(enabled: enabled, items: Map.unmodifiable(next));
  }

  PlaySkipPreferences remove(String vodId) => upsert(
      vodId, const PlaySkipEntry(openingMs: 0, endingMs: 0));

  PlaySkipPreferences copyWith({bool? enabled}) =>
      PlaySkipPreferences(enabled: enabled ?? this.enabled, items: items);

  /// 严格解析：版本 / 顶层类型非法抛出 [FormatException]；单条非法丢弃。
  static PlaySkipPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('片头片尾偏好格式无效');
    }
    final rawEnabled = json['enabled'];
    if (rawEnabled != null && rawEnabled is! bool) {
      throw const FormatException('片头片尾偏好格式无效');
    }
    final rawItems = json['items'];
    if (rawItems != null && rawItems is! Map) {
      throw const FormatException('片头片尾偏好格式无效');
    }
    final items = <String, PlaySkipEntry>{};
    if (rawItems is Map) {
      for (final entry in rawItems.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final parsed = PlaySkipEntry.tryFromJson(entry.value);
        if (parsed == null || parsed.isEmpty) continue;
        items[key] = parsed;
      }
    }
    return PlaySkipPreferences(
      enabled: rawEnabled as bool? ?? true,
      items: Map.unmodifiable(items),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'enabled': enabled,
        'items': {
          for (final entry in items.entries) entry.key: entry.value.toJson(),
        },
      };

  @override
  String toString() =>
      'PlaySkipPreferences(enabled: $enabled, items: ${items.length})';
}
