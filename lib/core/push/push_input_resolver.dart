import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../player/models/player_state.dart';

/// 将显式输入转换为可播放媒体，不自动读取剪贴板或保存数据。
class PushInputResolver {
  final Future<FileSystemEntityType> Function(Uri) _fileType;

  PushInputResolver({Future<FileSystemEntityType> Function(Uri)? fileType})
      : _fileType = fileType ?? _readFileType;

  Future<MediaPlaySpec> resolve(
    String input, {
    String? title,
    Map<String, String> headers = const {},
  }) async {
    final value = _unquote(input.trim());
    if (value.isEmpty || value.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('请输入单个媒体地址或文件路径');
    }
    final separator = value.indexOf('|');
    final address =
        (separator < 0 ? value : value.substring(0, separator)).trim();
    final requestHeaders = <String, String>{};
    void addHeaders(Map<String, String> values) {
      for (final entry in values.entries) {
        if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(entry.key) ||
            entry.value.contains(RegExp(r'[\x00-\x08\x0a-\x1f\x7f]'))) {
          throw const FormatException('播放请求头格式无效');
        }
        final key = switch (entry.key.toLowerCase()) {
          'user-agent' => 'User-Agent',
          'referer' || 'referrer' => 'Referer',
          'authorization' => 'Authorization',
          'cookie' => 'Cookie',
          'origin' => 'Origin',
          _ => entry.key.toLowerCase(),
        };
        requestHeaders[key] = entry.value;
      }
    }

    addHeaders(headers);
    if (separator >= 0) {
      try {
        addHeaders(Uri.splitQueryString(value.substring(separator + 1)));
      } on FormatException {
        throw const FormatException('播放请求头格式无效');
      }
    }

    Uri? uri;
    if (_windowsPath.hasMatch(address)) {
      if (RegExp(r'^\\\\[?.]\\').hasMatch(address)) {
        throw const FormatException('不支持 Windows 设备路径，请选择普通媒体文件');
      }
      uri = Uri.file(address, windows: true);
    } else {
      uri = Uri.tryParse(address);
    }
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('请输入完整媒体 URL、盘符路径或共享文件路径');
    }
    if (uri.scheme == 'magnet') {
      throw const FormatException('暂不支持磁力链，请使用已下载文件或媒体直链');
    }
    if (uri.scheme == 'smb') {
      final segments =
          uri.pathSegments.where((part) => part.isNotEmpty).toList();
      if (uri.host.isEmpty ||
          uri.host.contains(':') ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.hasPort && uri.port != 445) ||
          segments.length < 2 ||
          segments.any((part) => part.contains(RegExp(r'[/\\\x00]')))) {
        throw const FormatException(
            '请输入不含凭据的 smb://服务器/共享名/文件，先在 Windows 中登录共享');
      }
      uri = Uri(scheme: 'file', host: uri.host, pathSegments: segments);
    }

    if (uri.scheme == 'file') {
      final fileParts =
          uri.pathSegments.where((part) => part.isNotEmpty).toList();
      final absolutePath = uri.host.isEmpty
          ? RegExp(r'^/[A-Za-z]:/').hasMatch(uri.path)
          : uri.host != '.' && uri.host != '?' && fileParts.length >= 2;
      if (uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          !absolutePath) {
        throw const FormatException('文件 URI 无效，请使用完整文件路径');
      }
      if (requestHeaders.isNotEmpty) {
        throw const FormatException('本地或共享文件不使用 HTTP 请求头');
      }
      if (!isMediaFileName(
          uri.pathSegments.isEmpty ? '' : uri.pathSegments.last)) {
        throw const FormatException('请选择视频或音频文件，不支持目录、快捷方式和程序文件');
      }
      try {
        final type = await _fileType(uri).timeout(const Duration(seconds: 10));
        if (type != FileSystemEntityType.file) {
          throw const FormatException('文件不存在或不是普通文件，请确认共享已挂载并可访问');
        }
      } on FileSystemException {
        throw const FormatException('无法读取文件，请检查路径、权限或 Windows 共享登录状态');
      } on TimeoutException {
        throw const FormatException('读取文件超时，请检查共享是否在线');
      } on UnsupportedError {
        throw const FormatException('文件 URI 无效，请使用 Windows 文件路径');
      } on ArgumentError {
        throw const FormatException('文件 URI 无效，请使用 Windows 文件路径');
      }
    } else {
      if (!const {
            'http',
            'https',
            'rtmp',
            'rtmps',
            'rtsp',
            'rtsps',
            'udp',
            'rtp'
          }.contains(uri.scheme) ||
          uri.host.isEmpty ||
          (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
        throw const FormatException('不支持此地址，请输入 HTTP(S)、RTMP、RTSP、UDP 或媒体文件');
      }
      if ((uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.userInfo.isNotEmpty) {
        final parts = uri.userInfo.split(':');
        final username = Uri.decodeComponent(parts.first);
        final password = Uri.decodeComponent(parts.skip(1).join(':'));
        requestHeaders.putIfAbsent('Authorization',
            () => 'Basic ${base64Encode(utf8.encode('$username:$password'))}');
        uri = uri.replace(userInfo: '');
      }
    }

    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final defaultTitle = parts.isEmpty ? '推送媒体' : parts.last;
    return MediaPlaySpec(
      url: uri.toString(),
      title:
          title == null || title.trim().isEmpty ? defaultTitle : title.trim(),
      headers: requestHeaders.isEmpty ? null : Map.unmodifiable(requestHeaders),
    );
  }

  List<String> extractCandidates(String text) {
    final candidates = <String>{};
    final links = RegExp(
      r'''(?:https?|rtmps?|rtsps?|udp|rtp|file|smb|magnet):[^\s<>"']+''',
      caseSensitive: false,
    );
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = _unquote(rawLine.trim());
      if (line.isEmpty) continue;
      if (_windowsPath.hasMatch(line) ||
          line.toLowerCase().startsWith('file:')) {
        candidates.add(line);
        continue;
      }
      for (final match in links.allMatches(line)) {
        var value = match.group(0)!.replaceFirst(RegExp(r'[。，；！？、]+$'), '');
        while (value.endsWith(')') &&
            ')'.allMatches(value).length > '('.allMatches(value).length) {
          value = value.substring(0, value.length - 1);
        }
        while (value.endsWith(']') &&
            ']'.allMatches(value).length > '['.allMatches(value).length) {
          value = value.substring(0, value.length - 1);
        }
        candidates.add(value);
      }
    }
    return List.unmodifiable(candidates);
  }

  static const mediaExtensions = {
    'mp4',
    'mkv',
    'avi',
    'mov',
    'webm',
    'flv',
    'ts',
    'm2ts',
    'mts',
    'mpeg',
    'mpg',
    'm4v',
    'wmv',
    'vob',
    'ogv',
    '3gp',
    'm3u8',
    'mp3',
    'flac',
    'aac',
    'wav',
    'ogg',
    'm4a',
    'aiff',
    'opus',
    'wma',
  };

  static bool isMediaFileName(String name) => mediaExtensions
      .contains(p.extension(name).toLowerCase().replaceFirst('.', ''));

  static final _windowsPath = RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\|//)');

  static String _unquote(String text) {
    if (text.length > 1 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      return text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  static Future<FileSystemEntityType> _readFileType(Uri uri) =>
      FileSystemEntity.type(File.fromUri(uri).path);
}

String pushErrorMessage(Object error) =>
    error is FormatException ? error.message : '操作失败，请检查输入、文件权限或网络后重试';
