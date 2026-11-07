import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../config/models/vod_config.dart';
import 'live_playlist_parser.dart';

/// 将脚本描述的地址和 liveContent 的不同载体统一为可播放频道。
class LiveScriptCatalog {
  const LiveScriptCatalog();

  static String? encodeExt(Object? ext) => ext == null
      ? null
      : ext is String ? ext : jsonEncode(_canonicalJson(ext));

  /// RPC 注册、频道对账和书签必须使用同一身份，且不保存 ext 中的凭据。
  static String sourceKey(Live source) {
    final identity = jsonEncode([
      source.api?.trim() ?? '', encodeExt(source.ext),
      source.scriptKey?.trim() ?? '', source.url,
    ]);
    return 'live:${sha256.convert(utf8.encode(identity))}';
  }

  Live resolveSource(Live source, Uri? baseUri) => source.copyWith(
        api: _resolve(source.api, baseUri),
        url: LivePlaylistParser.resolveAddress(source.url, baseUri),
        epg: _resolve(source.epg, baseUri),
        logo: _resolve(source.logo, baseUri),
        ext: _resolveExt(source.ext, baseUri),
      );

  List<Live> parse(Object? content, {required Live source, Uri? baseUri}) {
    Object? decoded = content;
    List<Live> channels;
    if (decoded is String) {
      final text = decoded.replaceFirst('\uFEFF', '').trim();
      if (text.startsWith('<')) {
        throw const FormatException('脚本返回了网页，不是直播频道');
      }
      if (text.startsWith('{') || text.startsWith('[')) {
        decoded = jsonDecode(text);
      } else {
        channels = const LivePlaylistParser().parse(
          text,
          baseUri: baseUri,
          group: source.group,
          epg: source.epg,
          logo: source.logo,
          headers: source.headers,
        );
        return _finish(channels, source, baseUri);
      }
    }
    if (decoded is! List && decoded is! Map) {
      throw const FormatException('脚本未返回直播频道列表');
    }
    final root = _jsonShape(decoded);
    final entries = root is List
        ? root
        : root is Map && root['lives'] is List
            ? root['lives'] as List
            : [root];
    channels = VodConfig.fromJson({
      'lives': [
        {
          'group': source.group,
          'epg': source.epg,
          'logo': source.logo,
          'headers': source.headers,
          'format': source.format,
          'timeZone': source.timeZone,
          'groups': entries,
        },
      ],
    }).lives;
    return _finish(channels, source, baseUri);
  }

  List<Live> _finish(List<Live> channels, Live source, Uri? baseUri) {
    final scriptKey = sourceKey(source);
    final result = <String, Live>{};
    for (final channel in channels) {
      if (channel.isScripted || channel.isPlaylist || channel.name.isEmpty) {
        continue;
      }
      final lines = <LiveLine>[];
      for (final line in channel.lines) {
        final url = LivePlaylistParser.resolveAddress(line.url, baseUri);
        if (LivePlaylistParser.isStreamUrl(url)) {
          lines.add(LiveLine(name: line.name, url: url));
        }
      }
      final url = lines.isNotEmpty
          ? lines.first.url
          : LivePlaylistParser.resolveAddress(channel.url, baseUri);
      if (!LivePlaylistParser.isStreamUrl(url)) continue;
      final resolved = channel.copyWith(
        url: url,
        lines: List.unmodifiable(lines),
        epg: _resolve(channel.epg, baseUri),
        logo: _resolve(channel.logo, baseUri),
        scriptKey: scriptKey,
        format: channel.format ?? source.format,
        timeZone: channel.timeZone ?? source.timeZone,
      );
      result.putIfAbsent(resolved.key, () => resolved);
    }
    if (result.isEmpty) {
      throw const FormatException('脚本未返回有效的直播频道');
    }
    return List.unmodifiable(result.values);
  }

  static String? _resolve(String? value, Uri? baseUri) => value == null
      ? null
      : LivePlaylistParser.resolveAddress(value, baseUri);

  static Object? _resolveExt(Object? ext, Uri? baseUri) {
    if (ext is! String) return ext;
    final value = ext.trim();
    if (value.isEmpty || value.startsWith('{') || value.startsWith('[')) {
      return ext;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasScheme) return ext;
    final pathLike = value.startsWith('/') ||
        value.startsWith('./') ||
        value.startsWith('../') ||
        (!value.contains(':') && value.contains('/')) ||
        RegExp(r'^[\w\- .]+\.(?:json|txt|py|js)$', caseSensitive: false)
            .hasMatch(uri.path);
    return pathLike ? LivePlaylistParser.resolveAddress(value, baseUri) : ext;
  }

  static Object? _jsonShape(Object? value) {
    if (value is Map) {
      final result = <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _jsonShape(entry.value),
      };
      final rawUrls = value['urls'];
      final urls = rawUrls is List
          ? rawUrls
          : value['url'] is String ? [value['url']] : const [];
      final lines = <Map<String, String>>[];
      for (final raw in urls) {
        if (raw is! String || raw.trim().isEmpty) continue;
        final text = raw.trim();
        final split = text.lastIndexOf(r'$');
        final labelled = split > 0 && split < text.length - 1;
        lines.add({
          'name': labelled ? text.substring(split + 1) : '线路${lines.length + 1}',
          'url': labelled ? text.substring(0, split) : text,
        });
      }
      if (lines.isNotEmpty) {
        result['url'] = lines.first['url'];
        result['lines'] = lines;
      }
      return result;
    }
    if (value is List) return value.map(_jsonShape).toList();
    return value;
  }

  static Object? _canonicalJson(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((left, right) =>
            left.key.toString().compareTo(right.key.toString()));
      return {
        for (final entry in entries)
          entry.key.toString(): _canonicalJson(entry.value),
      };
    }
    if (value is List) return value.map(_canonicalJson).toList();
    return value;
  }
}
