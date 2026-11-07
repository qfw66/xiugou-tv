import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/models/vod_config.dart';
import 'live_source.dart';

/// 切换配置源后，在新直播目录中定位「切换前正在播放的频道」（方案 §4.3）。
///
/// 匹配顺序：脚本稳定身份 → 频道 key → 同分组同名的备用地址 → 名称 + 地址 → 名称（优先同分组）。
/// 返回 `index` 为 0 且 `found` 为 false 时，调用方应起播新配置的第一个频道。
typedef LiveReconcileResult = ({
  List<Live> channels,
  int index,
  String? scopeId,
  bool found,
  bool requiresRestart,
});

LiveReconcileResult reconcileLiveAfterConfigSwitch({
  required LiveCatalog catalog,
  required Live? current,
  required String? previousScopeId,
}) {
  final channels = List<Live>.unmodifiable(catalog.channels);
  if (current == null || channels.isEmpty) {
    return (channels: channels, index: 0, scopeId: null, found: false,
        requiresRestart: false);
  }

  final byKey = channels.indexWhere((channel) => channel.key == current.key);
  final byLine = channels.indexWhere((channel) => channel.matchesKey(current.key));
  final index = _indexByScript(channels,
          source: current.scriptKey, epgId: current.epgId,
          name: current.name, group: current.groupName) ??
      (byKey >= 0
          ? byKey
          : byLine >= 0
              ? byLine
              : _indexByNameAndUrl(channels, current) ??
                  _indexByName(channels, current) ?? -1);
  final next = index < 0 ? null : channels[index];

  return (
    channels: channels,
    index: index < 0 ? 0 : index,
    scopeId: null,
    found: index >= 0,
    requiresRestart: next != null &&
        (current.scriptKey != null || next.scriptKey != null) &&
        (current.url != next.url || !mapEquals(current.headers, next.headers) ||
            current.lines.length != next.lines.length ||
            current.lines.asMap().entries.any((entry) =>
                entry.value.url != next.lines[entry.key].url ||
                entry.value.name != next.lines[entry.key].name)),
  );
}

const _bookmarkPrefix = 'live-script-channel:';

/// 脚本代理地址只在本次 Companion 生命周期有效，不能作为跨重启书签。
String liveChannelBookmark(Live channel) {
  final source = channel.scriptKey;
  if (source == null || source.isEmpty) return channel.key;
  return '$_bookmarkPrefix${jsonEncode([
    source, channel.epgId ?? '', channel.name, channel.groupName,
  ])}';
}

int resolveLiveBookmark(List<Live> channels, String? bookmark) {
  if (bookmark == null || bookmark.isEmpty) return 0;
  final byKey = channels.indexWhere((channel) => channel.key == bookmark);
  if (byKey >= 0) return byKey;
  final byLine = channels.indexWhere((channel) => channel.matchesKey(bookmark));
  if (byLine >= 0) return byLine;
  if (!bookmark.startsWith(_bookmarkPrefix)) return 0;
  try {
    final value = jsonDecode(bookmark.substring(_bookmarkPrefix.length));
    if (value is! List || value.length != 4 || value.any((item) => item is! String)) {
      return 0;
    }
    return _indexByScript(channels, source: value[0] as String,
        epgId: value[1] as String, name: value[2] as String,
        group: value[3] as String) ?? 0;
  } on FormatException {
    return 0;
  }
}

int? _indexByScript(List<Live> channels, {required String? source,
    required String? epgId, required String name, required String group}) {
  if (source == null || source.isEmpty) return null;
  var fallback = -1;
  for (var i = 0; i < channels.length; i++) {
    final channel = channels[i];
    if (channel.scriptKey != source) continue;
    if (epgId != null && epgId.isNotEmpty
        ? channel.epgId != epgId
        : channel.name != name) {
      continue;
    }
    if (channel.groupName == group) return i;
    if (fallback < 0) fallback = i;
  }
  return fallback < 0 ? null : fallback;
}

int? _indexByNameAndUrl(List<Live> channels, Live current) {
  for (var i = 0; i < channels.length; i++) {
    final channel = channels[i];
    if (channel.name == current.name && channel.url == current.url) return i;
  }
  return null;
}

int? _indexByName(List<Live> channels, Live current) {
  var fallback = -1;
  for (var i = 0; i < channels.length; i++) {
    final channel = channels[i];
    if (channel.name != current.name) continue;
    if (channel.groupName == current.groupName) return i;
    if (fallback < 0) fallback = i;
  }
  return fallback < 0 ? null : fallback;
}
