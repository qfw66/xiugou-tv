import '../config/models/vod_config.dart';

/// 将 M3U / TVBox TXT 清单转换为频道；HLS 分片必须交给播放器处理。
class LivePlaylistParser {
  const LivePlaylistParser();

  List<Live> parse(
    String content, {
    Uri? baseUri,
    String? group,
    String? epg,
    String? logo,
    Map<String, String> headers = const {},
  }) {
    final text = content.replaceFirst('\uFEFF', '').trim();
    // 真正的 HLS 分片清单带 `#EXT-X-TARGETDURATION` 一类标签；直播频道表只带
    // `#EXT-X-APP` 等播放器自定义标签（Kimentanm / JackTV）。两者都可能含
    // `#EXTINF`，因此不能靠「出现 #EXT-X- 就拒绝」判定，而是在解析不到可播放
    // 频道时再用该标签区分「导入错文件」与「内容为空」两种提示。
    final hasHlsSegmentTag = RegExp(
            r'^#EXT-X-(TARGETDURATION|MEDIA-SEQUENCE|STREAM-INF|ENDLIST|BYTERANGE|DISCONTINUITY|KEY|MAP)',
            multiLine: true,
            caseSensitive: false)
        .hasMatch(text);
    final m3u =
        RegExp(r'^#EXT(?:M3U|INF)', multiLine: true, caseSensitive: false)
            .hasMatch(text);
    final channels = <String, Live>{};
    var activeGroup = group;
    var activeEpg = epg;
    Map<String, String>? pending;
    var pendingHeaders = <String, String>{...headers};

    void add(String name, String address, Map<String, String> attributes) {
      if (name.trim().isEmpty) return;
      final parts = address.split('|');
      final firstUrl = parts.first
          .split(
            RegExp(r'#(?=(?:https?|rtmps?|rtsps?|udp|rtp)://)',
                caseSensitive: false),
          )
          .first;
      // TXT 的 $ 后缀是线路标签；M3U 中的 $ 仍属于 URL 正文。
      final streamUrl = m3u ? firstUrl : firstUrl.split(r'$').first;
      final url = resolveAddress(streamUrl, baseUri);
      if (!isStreamUrl(url)) return;
      final requestHeaders = {...pendingHeaders};
      if (parts.length > 1) {
        try {
          requestHeaders
              .addAll(Uri.splitQueryString(parts.sublist(1).join('|')));
        } on FormatException {
          // 非法请求头不应损坏同一清单中的其他频道。
        }
      }
      var live = Live.fromJson({
        'name': name.trim(),
        'url': url,
        'group': _nonEmpty(attributes['group-title']) ?? activeGroup,
        'logo': _nonEmpty(attributes['tvg-logo']),
        'epg': _nonEmpty(attributes['tvg-url']),
        'epgId': attributes['tvg-id'],
        'epgName': attributes['tvg-name'],
        'headers': requestHeaders,
        'isPlaylist': false,
      }, defaultEpg: activeEpg, defaultLogo: logo);
      live = live.copyWith(
        logo: resolveAddress(live.logo ?? '', baseUri),
        epg: resolveAddress(live.epg ?? '', baseUri),
      );
      channels.putIfAbsent(live.key, () => live);
    }

    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();
      if (upper.startsWith('#EXTM3U')) {
        final attrs = _attributes(line);
        activeEpg ??= _nonEmpty(attrs['x-tvg-url']) ??
            _nonEmpty(attrs['url-tvg']) ??
            _nonEmpty(attrs['tvg-url']);
        // 多 EPG 声明按顺序选择第一个，避免将整串地址作为 URL 请求。
        activeEpg = activeEpg?.split(RegExp(r'[,;]\s*(?=https?://)')).first;
      } else if (upper.startsWith('#EXTINF:')) {
        final comma = _metadataComma(line);
        pending = _attributes(comma < 0 ? line : line.substring(0, comma));
        pending['name'] = comma < 0 ? '' : line.substring(comma + 1).trim();
        pendingHeaders = {...headers};
        final ua = _nonEmpty(pending['http-user-agent']);
        if (ua != null) pendingHeaders['User-Agent'] = ua;
        final referer = _nonEmpty(pending['http-referrer']);
        if (referer != null) pendingHeaders['Referer'] = referer;
      } else if (upper.startsWith('#EXTGRP:')) {
        activeGroup = _nonEmpty(line.substring(line.indexOf(':') + 1));
      } else if (upper.startsWith('#EXTVLCOPT:')) {
        final setting = line.substring(line.indexOf(':') + 1);
        final separator = setting.indexOf('=');
        if (separator < 0) continue;
        final key = setting.substring(0, separator).trim().toLowerCase();
        final value = setting.substring(separator + 1).trim();
        if (key == 'http-user-agent') pendingHeaders['User-Agent'] = value;
        if (key == 'http-referrer' || key == 'http-referer') {
          pendingHeaders['Referer'] = value;
        }
      } else if (!line.startsWith('#')) {
        if (m3u) {
          if (pending != null) {
            add(
              _nonEmpty(pending['name']) ??
                  _nonEmpty(pending['tvg-name']) ??
                  pending['tvg-id'] ??
                  '',
              line,
              pending,
            );
            pending = null;
            pendingHeaders = {...headers};
          }
        } else {
          final comma = line.indexOf(',');
          if (comma < 1) continue;
          final name = line.substring(0, comma).trim();
          final address = line.substring(comma + 1).trim();
          if (address.toLowerCase() == '#genre#') {
            activeGroup = name;
            pendingHeaders = {...headers};
          } else {
            add(name, address, const {});
          }
        }
      }
    }
    if (channels.isEmpty) {
      if (hasHlsSegmentTag) {
        throw const FormatException('这是 HLS 播放流，不是频道清单，请使用直链播放');
      }
      throw const FormatException('未找到有效频道，请导入带频道名称的 M3U 或 TXT 清单');
    }
    return List.unmodifiable(channels.values);
  }

  static bool isStreamUrl(String value) {
    if (value.contains(RegExp(r'[\x00-\x20]'))) return false;
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    if (uri.scheme == 'file') return uri.path.isNotEmpty;
    return const {
          'http',
          'https',
          'rtmp',
          'rtmps',
          'rtsp',
          'rtsps',
          'udp',
          'rtp'
        }.contains(uri.scheme.toLowerCase()) &&
        uri.host.isNotEmpty;
  }

  static String resolveAddress(String value, Uri? baseUri) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;
    return !uri.hasScheme && baseUri != null
        ? baseUri.resolveUri(uri).toString()
        : trimmed;
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  static Map<String, String> _attributes(String value) {
    final pattern = RegExp(
      r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))''',
    );
    return {
      for (final match in pattern.allMatches(value))
        match.group(1)!.toLowerCase():
            match.group(2) ?? match.group(3) ?? match.group(4) ?? '',
    };
  }

  static int _metadataComma(String value) {
    String? quote;
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (quote != null) {
        if (char == quote) quote = null;
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char == ',') {
        return i;
      }
    }
    return -1;
  }
}
