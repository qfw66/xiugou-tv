import '../player/models/player_state.dart';

/// 直链「按主机记忆播放方式」（D3：仅直链 + 按 host，最多 32 条）。
///
/// 只记 `Uri.host`（小写）到模式，不记完整 URL / 路径 / 频道名 —— 一次性签名
/// 会轮换，落盘完整地址既无用又容易泄露 token。选「自动」即删除该主机条目。
///
/// 落盘由 [LiveRepository] 负责（`live_direct_modes.json`，串行写队列 + 原子替换）；
/// 本类只做纯内存的容量 / LRU / 容错解析，便于单测。
class LiveDirectModeMemory {
  /// 上限（方案 §4.4：容量 32，LRU）。
  static const int maxEntries = 32;

  /// 落盘格式版本（旧文件无此键也按 1 处理）。
  static const int formatVersion = 1;

  /// 落盘文件名（与直播源同目录：`%APPDATA%/XiugouTV/`）。
  static const String fileName = 'live_direct_modes.json';

  final Map<String, PlaybackMode> _hosts;

  LiveDirectModeMemory([Map<String, PlaybackMode>? hosts])
      : _hosts = {...?hosts};

  /// 主机名归一：去空白 + 小写（`Uri.host` 本身已是小写，这里仍防御手工输入）。
  static String normalizeHost(String host) => host.trim().toLowerCase();

  int get length => _hosts.length;
  bool get isEmpty => _hosts.isEmpty;

  /// 当前条目（按最近使用顺序，最早的在前）。
  Map<String, PlaybackMode> get entries => Map.unmodifiable(_hosts);

  /// 命中即刷新 LRU 位置；未命中返回 null。
  PlaybackMode? modeFor(String host) {
    final key = normalizeHost(host);
    if (key.isEmpty) return null;
    final mode = _hosts.remove(key);
    if (mode != null) _hosts[key] = mode;
    return mode;
  }

  /// 记忆一个主机；超出上限时淘汰最早写入 / 最久未用的条目。
  void remember(String host, PlaybackMode mode) {
    final key = normalizeHost(host);
    if (key.isEmpty) return;
    _hosts.remove(key);
    while (_hosts.length >= maxEntries && _hosts.isNotEmpty) {
      _hosts.remove(_hosts.keys.first);
    }
    _hosts[key] = mode;
  }

  /// 删除一个主机（选「自动」= 下次重新探测）；返回是否确有删除。
  bool forget(String host) {
    final key = normalizeHost(host);
    if (key.isEmpty) return false;
    return _hosts.remove(key) != null;
  }

  void clear() => _hosts.clear();

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'hosts': {
          for (final entry in _hosts.entries) entry.key: entry.value.name,
        },
      };

  /// 容错解析：非 Map / 非 `hosts` 对象 / 非法模式值一律跳过（损坏文件 → 空表）。
  factory LiveDirectModeMemory.fromJson(Object? raw) {
    final memory = LiveDirectModeMemory();
    if (raw is! Map) return memory;
    final hosts = raw['hosts'];
    if (hosts is! Map) return memory;
    final parsed = <String, PlaybackMode>{};
    for (final entry in hosts.entries) {
      final host = normalizeHost(entry.key.toString());
      if (host.isEmpty) continue;
      final mode = _parseMode(entry.value);
      if (mode == null) continue;
      // 去重：后者覆盖前者，且保留「后来者更新」的顺序语义。
      parsed.remove(host);
      parsed[host] = mode;
    }
    // 超限（手工编辑过 / 旧版本写入更多）：保留最新的 maxEntries 条。
    final skip = parsed.length > maxEntries ? parsed.length - maxEntries : 0;
    for (final entry in parsed.entries.skip(skip)) {
      memory.remember(entry.key, entry.value);
    }
    return memory;
  }

  static PlaybackMode? _parseMode(Object? raw) =>
      switch (raw?.toString().trim().toLowerCase()) {
        'live' => PlaybackMode.live,
        'vod' => PlaybackMode.vod,
        _ => null,
      };

  /// 从 URL 取 host（非法 / 无 host 返回空串）。
  static String hostOfUrl(String url) =>
      normalizeHost(Uri.tryParse(url.trim())?.host ?? '');
}
