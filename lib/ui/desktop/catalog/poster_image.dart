import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/api/douban_repository.dart';
import 'douban_poster_image.dart';

/// 站源海报地址的解析结果。
///
/// 站源（FongMi / CatVod 体系）习惯把取图要带的请求头拼在地址尾巴上：
/// `https://host/a.jpg@Referer=https://x/@User-Agent=Mozilla/5.0 (...)`，
/// 也有 `@Headers={"Referer":"..."}`、`@Cookie=...`。手机端 `ImgUtil.getUrl` 会拆开，
/// 桌面端此前把整串原样交给 `NetworkImage`——地址非法或服务端 404，海报全空。
@immutable
class PosterSource {
  const PosterSource(this.url, {this.headers = const {}, this.fallbackUrl});

  /// 去掉 `@头=值` 尾巴后的真实地址
  final String url;

  /// 尾巴里声明的请求头（键已规范化，值已去首尾空白）
  final Map<String, String> headers;

  /// 主地址失败时再试的地址：站源中转（`…/db.php?url=<原图>`）挂掉时直取原图
  final String? fallbackUrl;

  /// 与 FongMi `ImgUtil.getUrl` 同口径：任一 `@Headers=` / `@Cookie=` / `@Referer=` /
  /// `@User-Agent=` 存在时，地址取第一个 `@` 之前；各值取到下一个 `@` 为止。
  static PosterSource parse(String pic) {
    final raw = pic.trim();
    final headers = <String, String>{};
    var hasParam = false;

    String? valueOf(String marker) {
      final at = raw.indexOf(marker);
      if (at < 0) return null;
      hasParam = true;
      final rest = raw.substring(at + marker.length);
      final end = rest.indexOf('@');
      return (end < 0 ? rest : rest.substring(0, end)).trim();
    }

    final json = valueOf('@Headers=');
    if (json != null && json.isNotEmpty) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k != null && v != null) headers[_fixHeader(k.toString())] = v.toString().trim();
          });
        }
      } catch (_) {
        // 非法 JSON：与手机端一样忽略这一段
      }
    }
    final cookie = valueOf('@Cookie=');
    if (cookie != null && cookie.isNotEmpty) headers['Cookie'] = cookie;
    final referer = valueOf('@Referer=');
    if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
    final ua = valueOf('@User-Agent=');
    if (ua != null && ua.isNotEmpty) headers['User-Agent'] = ua;

    final url = hasParam ? raw.substring(0, raw.indexOf('@')).trim() : raw;
    return PosterSource(url,
        headers: Map.unmodifiable(headers), fallbackUrl: _relayTarget(url));
  }

  /// `ua` / 任意大小写的 user-agent 统一成 `User-Agent`（对齐 FongMi `UrlUtil.fixHeader`）。
  static String _fixHeader(String key) {
    final k = key.trim();
    if (k.toLowerCase() == 'ua' || k.toLowerCase() == 'user-agent') return 'User-Agent';
    if (k.toLowerCase() == 'referer') return 'Referer';
    if (k.toLowerCase() == 'cookie') return 'Cookie';
    return k;
  }

  /// 站源图片中转：查询参数 `url` 本身是 http(s) 图片地址时，把它当回落。
  static String? _relayTarget(String url) {
    final q = url.indexOf('?');
    if (q < 0) return null;
    for (final part in url.substring(q + 1).split('&')) {
      if (!part.startsWith('url=')) continue;
      var value = part.substring(4);
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {
        // 原样使用
      }
      return value.startsWith('http://') || value.startsWith('https://')
          ? value
          : null;
    }
    return null;
  }

  bool get needsCustomFetch => headers.isNotEmpty || fallbackUrl != null;
}

/// 海报解码器的统一入口：所有站源海报都应走这里，不要再直接 `NetworkImage(pic)`。
///
/// - 空地址返回 null（调用方保留各自的占位逻辑）；
/// - 豆瓣图床走 [DoubanPosterImage]（自带 UA + Referer，webp 优先）；
/// - 带 `@头` 尾巴或有中转回落的走 [SitePosterImage]；
/// - 普通地址仍是 `NetworkImage`，行为与改动前一致。
ImageProvider? posterImageProvider(String pic, {int? targetWidth}) {
  if (pic.trim().isEmpty) return null;
  final source = PosterSource.parse(pic);
  if (source.url.isEmpty) return null;
  if (DoubanRepository.isDoubanPoster(source.url)) {
    return DoubanPosterImage(source.url, targetWidth: targetWidth);
  }
  if (source.needsCustomFetch) {
    return SitePosterImage(source, targetWidth: targetWidth);
  }
  final network = NetworkImage(source.url);
  return targetWidth == null ? network : ResizeImage(network, width: targetWidth);
}

/// 带自定义请求头 / 回落地址的站源海报。
///
/// 和 [DoubanPosterImage] 同理自己发请求：`NetworkImage(headers:)` 用 `headers.add`，
/// 会和 `dart:io` 默认 UA 叠成两条，校验 UA 的图床仍会拒图。
class SitePosterImage extends ImageProvider<SitePosterImage> {
  const SitePosterImage(this.source, {this.targetWidth});

  final PosterSource source;
  final int? targetWidth;

  static const Duration _timeout = Duration(seconds: 20);
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  @override
  Future<SitePosterImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<SitePosterImage>(this);

  @override
  ImageStreamCompleter loadImage(SitePosterImage key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(decode, chunkEvents),
      scale: 1.0,
      chunkEvents: chunkEvents.stream,
    );
  }

  /// 请求顺序：主地址（带声明的头）→ 回落地址（豆瓣图床换用豆瓣头）。
  @visibleForTesting
  List<MapEntry<String, Map<String, String>>> get attempts => [
        MapEntry(source.url, source.headers),
        if (source.fallbackUrl != null && source.fallbackUrl != source.url)
          MapEntry(
            source.fallbackUrl!,
            DoubanRepository.isDoubanPoster(source.fallbackUrl!)
                ? DoubanRepository.imageHeaders
                : source.headers,
          ),
      ];

  Future<ui.Codec> _load(
      ImageDecoderCallback decode, StreamController<ImageChunkEvent> chunkEvents) async {
    try {
      Object? lastError;
      for (final attempt in attempts) {
        try {
          final bytes = await _get(attempt.key, attempt.value);
          if (bytes.isEmpty) continue;
          final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
          return await decode(buffer, getTargetSize: _targetSize);
        } catch (error) {
          lastError = error;
        }
      }
      throw StateError('站源海报加载失败：${source.url}（$lastError）');
    } finally {
      unawaited(chunkEvents.close());
    }
  }

  ui.TargetImageSize _targetSize(int width, int height) {
    final target = targetWidth;
    if (target == null || target <= 0 || width <= target) {
      return ui.TargetImageSize(width: width, height: height);
    }
    return ui.TargetImageSize(width: target, height: (height * target / width).round());
  }

  static Future<Uint8List> _get(String url, Map<String, String> headers) async {
    final request = await _client.getUrl(Uri.parse(url)).timeout(_timeout);
    // 必须 set：add 会与 dart:io 默认 UA 叠成两条
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  bool operator ==(Object other) =>
      other is SitePosterImage &&
      other.source.url == source.url &&
      other.source.fallbackUrl == source.fallbackUrl &&
      mapEquals(other.source.headers, source.headers) &&
      other.targetWidth == targetWidth;

  @override
  int get hashCode => Object.hash(source.url, source.fallbackUrl,
      Object.hashAllUnordered(source.headers.entries.map((e) => '${e.key}=${e.value}')), targetWidth);

  @override
  String toString() => 'SitePosterImage("${source.url}", headers: ${source.headers.keys}, '
      'fallback: ${source.fallbackUrl}, targetWidth: $targetWidth)';
}
