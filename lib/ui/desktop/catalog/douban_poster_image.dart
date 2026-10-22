import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/api/douban_repository.dart';

/// 豆瓣海报解码器（§17）。
///
/// **为什么不能用 `Image.network`**：`NetworkImage` 是这样加头的——
/// `request.headers.add(name, value)`，而 `dart:io` 的 `HttpClient` 自带一条默认
/// `user-agent`，`add` 之后就成了两条 UA；服务端看到的不是浏览器 UA，豆瓣图床直接
/// 回 403。实测（同一张海报）：
///
/// | 请求方式 | 结果 |
/// |---|---|
/// | 裸 `HttpClient` + `set(UA, Referer)` | 200 `image/jpeg` |
/// | `NetworkImage(headers: 任何组合)` | **403**（等价于一个头都没发） |
///
/// 所以这里自己发请求、自己 `set`，顺带做两件 `NetworkImage` 做不到的事：
/// 1. **webp 优先**：豆瓣 CDN 会按后缀转码，同图 `.webp` 比 `.jpg` 小约 18%；
/// 2. **jpg 回落**：个别老资源没有 webp 变体时自动退回原地址，不会掉成占位图。
class DoubanPosterImage extends ImageProvider<DoubanPosterImage> {
  const DoubanPosterImage(this.url, {this.targetWidth, this.fallbackUrl});

  /// 海报原始地址（接口给的通常是 `.jpg`）
  final String url;

  /// 解码目标宽度（对应原来 `Image.network(cacheWidth:)` 的语义，只缩不放）
  final int? targetWidth;

  /// 高清地址失败时的回落地址（首页大屏把 `m_ratio_poster` 提到 `raw`，
  /// 个别老资源没有原图，此时退回接口给的缩略图，别掉成占位图）。
  final String? fallbackUrl;

  static const Duration _timeout = Duration(seconds: 20);

  /// 复用连接：一屏 18 张海报不必各建一个 HttpClient
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  @override
  Future<DoubanPosterImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<DoubanPosterImage>(this);

  @override
  ImageStreamCompleter loadImage(
      DoubanPosterImage key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode, chunkEvents),
      scale: 1.0,
      chunkEvents: chunkEvents.stream,
    );
  }

  Future<ui.Codec> _load(
    DoubanPosterImage key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    try {
      final bytes = await _fetch();
      if (bytes.isEmpty) {
        throw StateError('豆瓣海报响应为空：$url');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return await decode(buffer, getTargetSize: targetSizeFor);
    } finally {
      // 这一层不消费进度事件，立即关闭避免泄漏
      unawaited(chunkEvents.close());
    }
  }

  /// 解码目标尺寸：只缩不放，保持宽高比（对应原 `cacheWidth:` 语义）。
  @visibleForTesting
  ui.TargetImageSize targetSizeFor(int intrinsicWidth, int intrinsicHeight) {
    final target = targetWidth;
    if (target == null || target <= 0 || intrinsicWidth <= target) {
      return ui.TargetImageSize(width: intrinsicWidth, height: intrinsicHeight);
    }
    final height = (intrinsicHeight * target / intrinsicWidth).round();
    return ui.TargetImageSize(width: target, height: height);
  }

  /// webp 优先的候选地址：`.jpg` 先试 `.webp`，其余原样一个候选。
  ///
  /// 纯字符串逻辑，单独暴露给测试（不该为了验证它去联网）。
  @visibleForTesting
  static List<String> candidateUrls(String url) => <String>[
        if (url.toLowerCase().endsWith('.jpg'))
          '${url.substring(0, url.length - 4)}.webp',
        url,
      ];

  /// 实际请求顺序：主地址的 webp → jpg，再回落地址的 webp → jpg（去重）。
  ///
  /// 纯字符串逻辑，暴露给测试；`_fetch` 只负责按这个顺序发请求。
  @visibleForTesting
  static List<String> fetchCandidates({
    required String url,
    String? fallbackUrl,
  }) {
    final seen = <String>{};
    return <String>[
      ...candidateUrls(url),
      if (fallbackUrl != null && fallbackUrl != url)
        ...candidateUrls(fallbackUrl),
    ].where(seen.add).toList(growable: false);
  }

  /// 先要 `.webp`；失败（404 / 非 200）再回落原地址；高清地址整轮失败后
  /// 再试 [fallbackUrl] 的候选，最后才交给占位图。
  Future<Uint8List> _fetch() async {
    final candidates = fetchCandidates(url: url, fallbackUrl: fallbackUrl);
    Object? lastError;
    for (final candidate in candidates) {
      try {
        final bytes = await _get(candidate);
        if (bytes.isNotEmpty) return bytes;
      } catch (error) {
        lastError = error;
      }
    }
    assert(() {
      // 只在 debug 构建里留痕：线上失败就走占位图，不刷日志
      debugPrint('[xiugou-tv] 豆瓣海报加载失败：$url（$lastError）');
      return true;
    }());
    throw StateError('豆瓣海报加载失败：$url（$lastError）');
  }

  static Future<Uint8List> _get(String url) async {
    final request =
        await _client.getUrl(Uri.parse(url)).timeout(_timeout);
    // 必须用 set：add 会和 dart:io 默认 UA 叠成两条，豆瓣直接 403
    DoubanRepository.imageHeaders.forEach(request.headers.set);
    request.headers.set('Accept', 'image/avif,image/webp,image/*,*/*;q=0.8');
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
      other is DoubanPosterImage &&
      other.url == url &&
      other.targetWidth == targetWidth &&
      other.fallbackUrl == fallbackUrl;

  @override
  int get hashCode => Object.hash(url, targetWidth, fallbackUrl);

  @override
  String toString() =>
      'DoubanPosterImage("$url", targetWidth: $targetWidth, '
      'fallback: $fallbackUrl)';
}
