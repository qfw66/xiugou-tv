import 'package:path/path.dart' as p;

import '../config/models/vod_config.dart';

/// 独立直播源的内容类型：频道清单（txt / m3u / m3u8）或完整配置 JSON（只取 lives）。
enum LiveSourceKind { playlist, config }

/// 「直播源」历史中的一项。
///
/// [lives] 只在 [LiveSourceKind.config] 时有值：配置里 lives 段的快照，
/// 重启后直接复用，不必重新下载整份配置。清单类型只记地址，频道每次按地址拉取。
class LiveSourceEntry {
  final String location;
  final LiveSourceKind kind;
  final int lastUsedAt;
  final int channelCount;
  final List<Live> lives;

  const LiveSourceEntry({
    required this.location,
    required this.kind,
    required this.lastUsedAt,
    this.channelCount = 0,
    this.lives = const [],
  });

  /// 列表与卡片上的短名称：远程取「主机 / 末段文件名」，本地取文件名。
  String get displayName {
    final uri = Uri.tryParse(location);
    if (uri != null && uri.scheme == 'file') {
      final name = p.basename(uri.toFilePath(windows: true));
      return name.isEmpty ? location : name;
    }
    if (uri != null && uri.host.isNotEmpty) {
      final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
      return segments.isEmpty ? uri.host : '${uri.host}/${segments.last}';
    }
    return location;
  }

  LiveSourceEntry copyWith({
    int? lastUsedAt,
    int? channelCount,
    List<Live>? lives,
  }) =>
      LiveSourceEntry(
        location: location,
        kind: kind,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        channelCount: channelCount ?? this.channelCount,
        lives: lives ?? this.lives,
      );

  static LiveSourceEntry? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final location = json['location'];
    if (location is! String || location.trim().isEmpty) return null;
    final kind = switch (json['kind']) {
      'playlist' => LiveSourceKind.playlist,
      'config' => LiveSourceKind.config,
      _ => null,
    };
    if (kind == null) return null;
    final rawLives = json['lives'];
    return LiveSourceEntry(
      location: location.trim(),
      kind: kind,
      lastUsedAt: json['lastUsedAt'] is int ? json['lastUsedAt'] as int : 0,
      channelCount:
          json['channelCount'] is int ? json['channelCount'] as int : 0,
      lives: kind == LiveSourceKind.config && rawLives is List
          ? List.unmodifiable(rawLives
              .whereType<Map>()
              .map((item) => Live.fromJson(Map<String, dynamic>.from(item)))
              .where((live) => live.isScripted || live.url.isNotEmpty))
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'location': location,
        'kind': kind.name,
        'lastUsedAt': lastUsedAt,
        'channelCount': channelCount,
        if (kind == LiveSourceKind.config)
          'lives': lives.map((live) => live.toJson()).toList(),
      };
}

/// 独立直播源设置（live_source_history.json）：当前选中的地址 + 历史。
///
/// [active] 为 null 表示直播跟随主配置源；文件不存在时等同于此（老用户升级后行为不变）。
class LiveSourceHistory {
  static const int maxEntries = 30;
  static const LiveSourceHistory empty = LiveSourceHistory();

  final String? active;
  final List<LiveSourceEntry> entries;

  const LiveSourceHistory({this.active, this.entries = const []});

  LiveSourceEntry? get activeEntry {
    if (active == null) return null;
    for (final entry in entries) {
      if (entry.location == active) return entry;
    }
    return null;
  }

  /// 设为当前：同地址的旧记录被替换并移到最前，超出上限丢弃最旧的。
  LiveSourceHistory activate(LiveSourceEntry entry) => LiveSourceHistory(
        active: entry.location,
        entries: List.unmodifiable([
          entry,
          ...entries.where((item) => item.location != entry.location),
        ].take(maxEntries)),
      );

  /// 删除一条；删除的是当前项时回退主配置源（[active] 置空）。
  LiveSourceHistory remove(String location) => LiveSourceHistory(
        active: active == location ? null : active,
        entries: List.unmodifiable(
            entries.where((entry) => entry.location != location)),
      );

  LiveSourceHistory deactivate() => LiveSourceHistory(entries: entries);

  /// 只更新已有记录（刷新配置快照 / 频道数），不改变当前项与顺序。
  LiveSourceHistory replace(LiveSourceEntry entry) => LiveSourceHistory(
        active: active,
        entries: List.unmodifiable(entries.map((item) =>
            item.location == entry.location ? entry : item)),
      );

  factory LiveSourceHistory.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('直播源历史格式无效');
    final rawEntries = json['entries'];
    final entries = <LiveSourceEntry>[];
    if (rawEntries is List) {
      for (final raw in rawEntries) {
        final entry = LiveSourceEntry.tryFromJson(raw);
        if (entry == null ||
            entries.any((item) => item.location == entry.location)) {
          continue;
        }
        entries.add(entry);
        if (entries.length >= maxEntries) break;
      }
    }
    final active = json['active'];
    final history = LiveSourceHistory(
      active: active is String && active.trim().isNotEmpty
          ? active.trim()
          : null,
      entries: List.unmodifiable(entries),
    );
    // 指向已不存在的记录时按「跟随主配置源」处理。
    return history.activeEntry == null && history.active != null
        ? history.deactivate()
        : history;
  }

  Map<String, dynamic> toJson() => {
        'active': active,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      };
}

/// [LiveRepository.applySourceInput] 的结果：要么切换了直播源，要么新增 / 更新了一个手动频道。
class LiveSourceApplyResult {
  final LiveSourceEntry? source;
  final Live? channel;

  /// 手动频道已存在（同一地址），本次只更新了名称。
  final bool updated;

  const LiveSourceApplyResult.source(LiveSourceEntry this.source)
      : channel = null,
        updated = false;

  const LiveSourceApplyResult.channel(Live this.channel, {this.updated = false})
      : source = null;
}
