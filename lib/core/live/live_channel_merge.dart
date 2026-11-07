import '../config/models/vod_config.dart';

/// source 标记仅在一次目录加载中有效；null 表示独立的手动频道。
typedef LiveChannelEntry = ({Live channel, Object? source});

/// 按来源合并播放与节目单身份兼容的同名频道，保留旧 key 的首项优先规则。
List<Live> mergeLiveChannels(Iterable<LiveChannelEntry> entries) {
  final seenKeys = <String>{};
  final groups = <(Object, String, String), List<_ChannelGroup>>{};
  final ordered = <_ChannelGroup>[];
  for (final entry in entries) {
    final channel = entry.channel;
    if (!seenKeys.add(channel.key)) continue;
    final source = entry.source;
    if (source == null) {
      ordered.add(_ChannelGroup(channel));
      continue;
    }
    final candidates = groups.putIfAbsent(
        (source, channel.groupName, channel.name), () => []);
    _ChannelGroup? match;
    for (final candidate in candidates) {
      if (_compatible(candidate.first, channel)) {
        match = candidate;
        break;
      }
    }
    if (match == null) {
      final group = _ChannelGroup(channel);
      candidates.add(group);
      ordered.add(group);
    } else {
      match.channels.add(channel);
    }
  }
  return List.unmodifiable(ordered.map((group) => group.build()));
}

bool _compatible(Live first, Live next) =>
    _sameValue(first.headers, next.headers) &&
    first.scriptKey == next.scriptKey &&
    first.api == next.api &&
    _sameValue(first.ext, next.ext) &&
    first.epg == next.epg &&
    first.epgId == next.epgId &&
    first.epgName == next.epgName &&
    first.timeZone == next.timeZone &&
    first.timeout == next.timeout &&
    first.format == next.format &&
    first.playbackMode == next.playbackMode &&
    first.playbackModeSource == next.playbackModeSource &&
    first.playbackModeReason == next.playbackModeReason;

bool _sameValue(Object? first, Object? next) {
  if (identical(first, next)) return true;
  if (first is Map && next is Map) {
    return first.length == next.length &&
        first.keys.every((key) =>
            next.containsKey(key) && _sameValue(first[key], next[key]));
  }
  if (first is List && next is List) {
    if (first.length != next.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (!_sameValue(first[index], next[index])) return false;
    }
    return true;
  }
  return first == next;
}

class _ChannelGroup {
  _ChannelGroup(this.first) : channels = [first];

  final Live first;
  final List<Live> channels;

  Live build() {
    if (channels.length == 1) return first;
    final urls = <String>{};
    final lines = <LiveLine>[];
    void add(String url, String name) {
      if (!urls.add(url)) return;
      lines.add(LiveLine(
        name: name.trim().isEmpty ? '线路${lines.length + 1}' : name,
        url: url,
      ));
    }

    for (final channel in channels) {
      if (!channel.lines.any((line) => line.url == channel.url)) {
        add(channel.url, '');
      }
      for (final line in channel.lines) {
        add(line.url, line.name);
      }
    }
    final reservedNames = lines.map((line) => line.name).toSet();
    final usedNames = <String>{};
    final distinctLines = <LiveLine>[];
    for (final line in lines) {
      var name = line.name;
      if (usedNames.contains(name)) {
        var suffix = 2;
        do {
          name = '${line.name}（${suffix++}）';
        } while (reservedNames.contains(name) || usedNames.contains(name));
      }
      usedNames.add(name);
      distinctLines.add(LiveLine(name: name, url: line.url));
    }
    return first.copyWith(lines: List.unmodifiable(distinctLines));
  }
}
