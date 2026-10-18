import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import '../player/models/player_state.dart';
import 'push_input_resolver.dart';

/// 连接凭据只保存在内存，输出的目录与媒体地址须位于同源的选定根目录内。
class WebDavConnection {
  final Uri root;
  final Map<String, String> headers;

  const WebDavConnection._(this.root, this.headers);

  factory WebDavConnection.parse(
    String url, {
    String username = '',
    String password = '',
  }) {
    var uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !_safePath(uri) ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('请输入不含凭据、查询参数或片段的完整 HTTP(S) WebDAV 根地址');
    }
    if (!uri.path.endsWith('/')) uri = Uri.parse('$uri/');
    final user = username.trim();
    if (user.contains(':') || (user.isEmpty && password.isNotEmpty)) {
      throw const FormatException('WebDAV 用户名不能为空或包含冒号');
    }
    return WebDavConnection._(
        uri,
        Map.unmodifiable({
          if (user.isNotEmpty)
            'Authorization':
                'Basic ${base64Encode(utf8.encode('$user:$password'))}',
        }));
  }

  bool contains(Uri uri) {
    if (uri.scheme != root.scheme ||
        uri.host != root.host ||
        uri.port != root.port ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !_safePath(uri)) {
      return false;
    }
    final parent = _segments(root);
    final child = _segments(uri);
    return child.length >= parent.length &&
        List.generate(parent.length, (index) => parent[index] == child[index])
            .every((matches) => matches);
  }

  MediaPlaySpec playSpec(WebDavEntry entry) {
    if (!contains(entry.uri) || entry.isDirectory || !entry.isMedia) {
      throw const FormatException('请选择此 WebDAV 目录中的媒体文件');
    }
    return MediaPlaySpec(
      url: entry.uri.toString(),
      title: entry.name,
      headers: headers.isEmpty ? null : headers,
    );
  }
}

class WebDavEntry {
  final Uri uri;
  final String name;
  final bool isDirectory;
  final bool isMedia;
  final int? size;

  const WebDavEntry({
    required this.uri,
    required this.name,
    required this.isDirectory,
    required this.isMedia,
    this.size,
  });
}

/// 只读 WebDAV 浏览；不自动跟随重定向，也不对根目录外的 href 发请求。
class WebDavRepository {
  final Dio _dio;
  final bool _ownsDio;
  bool _disposed = false;

  WebDavRepository({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  Future<List<WebDavEntry>> list(
    WebDavConnection connection, {
    Uri? directory,
  }) async {
    if (_disposed) throw StateError('WebDAV 连接已关闭');
    final target = directory ?? connection.root;
    if (!connection.contains(target) || !target.path.endsWith('/')) {
      throw const FormatException('不能访问选定 WebDAV 根目录之外的位置');
    }
    try {
      final response = await _dio.requestUri<ResponseBody>(
        target,
        data: '<?xml version="1.0" encoding="UTF-8"?>'
            '<d:propfind xmlns:d="DAV:"><d:prop>'
            '<d:displayname/><d:resourcetype/><d:getcontentlength/>'
            '<d:getcontenttype/></d:prop></d:propfind>',
        options: Options(
          method: 'PROPFIND',
          headers: {
            ...connection.headers,
            'Depth': '1',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status != 200 && status != 207) {
        await response.data?.stream.listen((_) {}).cancel();
        if (status == 401 || status == 403) {
          throw const FormatException('WebDAV 认证失败或无访问权限，请检查用户名和密码');
        }
        if (status >= 300 && status < 400) {
          throw const FormatException('WebDAV 返回重定向，请填写最终目录地址后重试');
        }
        throw FormatException('WebDAV 返回 HTTP $status');
      }
      final body = response.data;
      if (body == null) throw const FormatException('WebDAV 返回空内容');
      final buffer = BytesBuilder(copy: false);
      await for (final chunk
          in body.stream.timeout(const Duration(seconds: 15))) {
        if (buffer.length + chunk.length > 5 * 1024 * 1024) {
          throw const FormatException('WebDAV 目录响应过大，请使用范围更小的根目录');
        }
        buffer.add(chunk);
      }
      if (_disposed) throw StateError('WebDAV 连接已关闭');
      return _parse(utf8.decode(buffer.takeBytes()), connection, target);
    } on DioException {
      throw const FormatException('WebDAV 连接失败，请检查服务地址、证书和网络');
    } on TimeoutException {
      throw const FormatException('WebDAV 请求超时，请检查网络后重试');
    } on XmlException {
      throw const FormatException('WebDAV 返回的 XML 无法解析');
    }
  }

  List<WebDavEntry> _parse(
    String text,
    WebDavConnection connection,
    Uri directory,
  ) {
    final document = XmlDocument.parse(text);
    if (document.rootElement.name.local != 'multistatus') {
      throw const FormatException('返回内容不是 WebDAV 目录，请确认服务根地址');
    }
    final entries = <String, WebDavEntry>{};
    final parent = _segments(directory);
    for (final response in _children(document.rootElement, 'response')) {
      final href = _childText(response, 'href');
      final reference = Uri.tryParse(href);
      if (reference == null || href.isEmpty || !_safePath(reference)) continue;
      var uri = directory.resolveUri(reference);
      if (!connection.contains(uri)) continue;
      final path = _segments(uri);
      if (path.length != parent.length + 1 ||
          !List.generate(parent.length, (index) => parent[index] == path[index])
              .every((matches) => matches)) {
        continue;
      }

      final properties = <String, XmlElement>{};
      var successful = false;
      for (final propstat in _children(response, 'propstat')) {
        if (!RegExp(r'^\s*HTTP/\S+\s+2\d\d(?:\s|$)', caseSensitive: false)
            .hasMatch(_childText(propstat, 'status'))) {
          continue;
        }
        successful = true;
        for (final prop in _children(propstat, 'prop')) {
          for (final property in prop.childElements) {
            properties[property.name.local] = property;
          }
        }
      }
      if (!successful) continue;
      final type = properties['resourcetype'];
      final isDirectory =
          type != null && _children(type, 'collection').isNotEmpty;
      if (isDirectory && !uri.path.endsWith('/')) uri = Uri.parse('$uri/');
      final display = properties['displayname']?.innerText.trim() ?? '';
      final contentType =
          properties['getcontenttype']?.innerText.toLowerCase() ?? '';
      final size =
          int.tryParse(properties['getcontentlength']?.innerText.trim() ?? '');
      final entry = WebDavEntry(
        uri: uri,
        name: display.isEmpty ? path.last : display,
        isDirectory: isDirectory,
        isMedia: !isDirectory &&
            (PushInputResolver.isMediaFileName(path.last) ||
                contentType.startsWith('video/') ||
                contentType.startsWith('audio/') ||
                contentType.startsWith('application/vnd.apple.mpegurl') ||
                contentType.startsWith('application/x-mpegurl')),
        size: size != null && size >= 0 ? size : null,
      );
      entries.putIfAbsent(uri.toString(), () => entry);
    }
    return List.unmodifiable(entries.values.toList()
      ..sort((left, right) {
        if (left.isDirectory != right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      }));
  }

  void dispose() {
    _disposed = true;
    if (_ownsDio) _dio.close(force: true);
  }
}

Iterable<XmlElement> _children(XmlElement element, String name) =>
    element.childElements.where((child) => child.name.local == name);

String _childText(XmlElement element, String name) {
  final nodes = _children(element, name);
  return nodes.isEmpty ? '' : nodes.first.innerText.trim();
}

List<String> _segments(Uri uri) =>
    uri.pathSegments.where((part) => part.isNotEmpty).toList();

bool _safePath(Uri uri) => uri.pathSegments.every((part) =>
    part != '.' && part != '..' && !part.contains(RegExp(r'[/\\\x00]')));
