/// 启动偏好与「上次入口」记录。
///
/// 持久化于应用数据目录的 `startup_preferences.json`（version 1）。
/// 读取规则：结构 / 版本 / 字段类型非法视为损坏并抛出 [FormatException]（由调用方处理）；
/// 未知枚举值归一化为默认（点播首页 / 无记录）。
class StartupPreferences {
  static const int formatVersion = 1;

  /// 「下次进入页面」偏好；默认点播首页
  final StartupEntry nextEntry;

  /// 「上次入口」记录；只允许点播 / 直播，缺失或非法时为 null
  final StartupEntry? lastEntry;

  const StartupPreferences({this.nextEntry = StartupEntry.vod, this.lastEntry});

  /// 本次启动的有效主入口：「上次入口」无有效记录时回退点播首页
  StartupEntry get effectiveEntry {
    if (nextEntry == StartupEntry.live) return StartupEntry.live;
    if (nextEntry == StartupEntry.last && lastEntry == StartupEntry.live) return StartupEntry.live;
    return StartupEntry.vod;
  }

  /// 归一化：[lastEntry] 仅保留点播 / 直播记录
  StartupPreferences normalized() => StartupPreferences(
        nextEntry: nextEntry,
        lastEntry: (lastEntry == StartupEntry.vod || lastEntry == StartupEntry.live) ? lastEntry : null,
      );

  StartupPreferences copyWith({StartupEntry? nextEntry, StartupEntry? lastEntry}) => StartupPreferences(
        nextEntry: nextEntry ?? this.nextEntry,
        lastEntry: lastEntry ?? this.lastEntry,
      );

  /// 严格解析：结构 / 版本 / 字段类型非法时抛出 [FormatException]；未知枚举值归一化为默认值。
  static StartupPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != formatVersion) {
      throw const FormatException('启动偏好格式无效');
    }
    final rawNext = json['nextEntry'];
    if (rawNext != null && rawNext is! String) {
      throw const FormatException('启动偏好格式无效');
    }
    final rawLast = json['lastEntry'];
    if (rawLast != null && rawLast is! String) {
      throw const FormatException('启动偏好格式无效');
    }
    final parsedLast = StartupEntry.tryParse(rawLast);
    return StartupPreferences(
      nextEntry: StartupEntry.tryParse(rawNext) ?? StartupEntry.vod,
      lastEntry: (parsedLast == StartupEntry.vod || parsedLast == StartupEntry.live) ? parsedLast : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'nextEntry': nextEntry.value,
        'lastEntry':
            (lastEntry == StartupEntry.vod || lastEntry == StartupEntry.live) ? lastEntry!.value : null,
      };

  @override
  bool operator ==(Object other) =>
      other is StartupPreferences && other.nextEntry == nextEntry && other.lastEntry == lastEntry;

  @override
  int get hashCode => Object.hash(nextEntry, lastEntry);

  @override
  String toString() => 'StartupPreferences(nextEntry: ${nextEntry.value}, lastEntry: ${lastEntry?.value})';
}

/// 可恢复的主入口类型
enum StartupEntry {
  /// 点播首页
  vod('vod'),

  /// 直播入口
  live('live'),

  /// 恢复上次入口
  last('last');

  final String value;

  const StartupEntry(this.value);

  /// 按持久化值解析；未知值返回 null（调用方决定回退）
  static StartupEntry? tryParse(Object? value) {
    for (final entry in StartupEntry.values) {
      if (entry.value == value) return entry;
    }
    return null;
  }
}
