import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../net/http_client_factory.dart';

/// CatVod 的 subs 是本集的独立资源，不继承媒体地址的协议或本地文件权限。
class SourceSubtitle {
  const SourceSubtitle._(this.name, this.uri);

  final String name;
  final Uri uri;

  static bool _isHttp(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;

  static List<SourceSubtitle> parse(Object? raw) {
    if (raw is! List) return const [];
    final items = <SourceSubtitle>[];
    final seen = <Uri>{};
    for (final item in raw) {
      if (item is! Map || item['url'] is! String) continue;
      final uri = Uri.tryParse(
        (item['url'] as String).trim(),
      )?.removeFragment();
      if (uri == null || !_isHttp(uri) || !seen.add(uri)) continue;
      final name = item['name']?.toString().trim() ?? '';
      items.add(
        SourceSubtitle._(name.isEmpty ? '站源字幕 ${items.length + 1}' : name, uri),
      );
      if (items.length == 32) break;
    }
    return List.unmodifiable(items);
  }

  /// 手动跟随跳转，只在字幕与媒体同源时使用站源请求头。限制的是解压后的正文大小。
  Future<String> readText({
    required String mediaUrl,
    Map<String, String>? headers,
    String? Function()? proxy,
  }) async {
    const limit = 2 * 1024 * 1024;
    final media = Uri.tryParse(mediaUrl);
    final client = HttpClientFactory.createHttpClient(
      connectionTimeout: const Duration(seconds: 5),
    );
    client.findProxy = (u) =>
        u.host == 'localhost' ||
            InternetAddress.tryParse(u.host)?.isLoopback == true
        ? 'DIRECT'
        : HttpClientFactory.pacFor(proxy?.call());
    Future<String> read() async {
      var url = uri;
      var forwardHeaders =
          media != null && _isHttp(media) && media.origin == url.origin;
      for (var redirects = 0; redirects <= 3; redirects++) {
        final request = await client.getUrl(url);
        request.followRedirects = false;
        if (forwardHeaders) {
          for (final entry in (headers ?? const <String, String>{}).entries) {
            if (!const {
              'host',
              'range',
              'connection',
              'content-length',
              'transfer-encoding',
            }.contains(entry.key.toLowerCase())) {
              request.headers.set(entry.key, entry.value);
            }
          }
        }
        final response = await request.close();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          final next = location == null ? null : url.resolve(location);
          if (next == null || !_isHttp(next)) break;
          await response.listen(null).cancel();
          forwardHeaders = forwardHeaders && next.origin == url.origin;
          url = next;
          continue;
        }
        if (response.statusCode != HttpStatus.ok ||
            response.contentLength > limit) {
          break;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final part in response) {
          if (bytes.length + part.length > limit) {
            throw const FormatException('字幕过大');
          }
          bytes.add(part);
        }
        final text = _decode(bytes.takeBytes());
        // 不把返回的登录页、媒体清单或二进制文件当作字幕交给原生播放器。
        final head = text.trimLeft();
        if (!text.contains('\x00') &&
            (head.startsWith('WEBVTT') ||
                head.startsWith('[Script Info]') ||
                RegExp(
                  r'^(?:\d+\s+)?\d{1,2}:\d\d:\d\d[,.]\d{1,3}\s+-->',
                ).hasMatch(head))) {
          return text;
        }
        break;
      }
      throw const FormatException('没有取得可用的文本字幕');
    }

    try {
      return await read().timeout(const Duration(seconds: 12));
    } finally {
      client.close(force: true);
    }
  }

  static String _decode(Uint8List bytes) {
    if (bytes.length >= 2) {
      final data = ByteData.sublistView(bytes);
      final bom = data.getUint16(0);
      if (bom == 0xfffe || bom == 0xfeff) {
        if (bytes.length.isOdd) throw const FormatException('UTF-16 字幕长度无效');
        final endian = bom == 0xfffe ? Endian.little : Endian.big;
        return String.fromCharCodes([
          for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian),
        ]);
      }
    }
    return utf8.decode(bytes);
  }
}
