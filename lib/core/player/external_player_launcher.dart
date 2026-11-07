import 'dart:io';

import '../settings/models/external_player_settings.dart';
import 'models/player_state.dart';

/// 参数与警告均为独立的只读快照；不要将参数写入日志。
class ExternalPlayerLaunchPlan {
  final String executable;
  final List<String> arguments;
  final List<String> warnings;

  ExternalPlayerLaunchPlan({
    required this.executable,
    required List<String> arguments,
    List<String> warnings = const [],
  })  : arguments = List<String>.unmodifiable(arguments),
        warnings = List<String>.unmodifiable(warnings);
}

/// 启动器仅产生固定的安全消息，不携带原始异常或媒体凭据。
class ExternalPlayerLaunchException implements Exception {
  final String message;

  const ExternalPlayerLaunchException(this.message);

  @override
  String toString() => message;
}

/// 将已解析的媒体交给本机程序；播放状态与历史记录仍由调用方管理。
class ExternalPlayerLauncher {
  static const int _maxCommandLineCodeUnits = 30000;
  static final RegExp _controlCharacters =
      RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]');
  static final RegExp _driveRoot = RegExp(r'^[A-Za-z]:[\\/]');
  static final RegExp _invalidPathCharacters = RegExp(r'[<>:"|?*]');
  static final RegExp _pathSeparator = RegExp(r'[\\/]');
  static final RegExp _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final RegExp _hostWhitespace = RegExp(r'\s');
  static const Set<String> _mediaSchemes = {
    'http',
    'https',
    'rtsp',
    'rtmp',
    'file',
  };

  final Future<void> Function(String, List<String>) _start;
  final Future<bool> Function(String) _fileExists;
  final bool _isWindows;

  ExternalPlayerLauncher({
    Future<void> Function(String, List<String>)? start,
    Future<bool> Function(String)? fileExists,
    bool? isWindows,
  })  : _start = start ?? _startDetached,
        _fileExists = fileExists ?? ((path) => File(path).exists()),
        _isWindows = isWindows ?? Platform.isWindows;

  ExternalPlayerLaunchPlan buildPlan({
    required ExternalPlayerSettings settings,
    required MediaPlaySpec spec,
    Duration position = Duration.zero,
  }) {
    _validateExecutable(settings.executablePath);
    _validateUrl(spec.url);
    final title = spec.title;
    if (title != null && _controlCharacters.hasMatch(title)) {
      throw const ExternalPlayerLaunchException('影片标题包含不支持的控制字符。');
    }
    final headers = spec.headers ?? const <String, String>{};
    for (final header in headers.entries) {
      if (!_headerName.hasMatch(header.key) ||
          _controlCharacters.hasMatch(header.key) ||
          _controlCharacters.hasMatch(header.value)) {
        throw const ExternalPlayerLaunchException('播放请求头格式无效。');
      }
    }

    final arguments = <String>[];
    final warnings = <String>[];
    final hasPosition = !spec.isLive && position > Duration.zero;
    switch (settings.kind) {
      case ExternalPlayerKind.generic:
        if (headers.isNotEmpty) {
          warnings.add('通用播放器仅传递播放地址，无法传递请求头，播放可能失败。');
        }
        if (hasPosition) {
          warnings.add('通用播放器无法传递起播进度，将从播放器的默认位置开始播放。');
        }
        arguments.add(spec.url);
      case ExternalPlayerKind.mpv:
        if (hasPosition) arguments.add('--start=${_seconds(position)}');
        if (title != null && title.isNotEmpty) {
          arguments.add('--force-media-title=$title');
        }
        arguments.add('--http-header-fields=');
        for (final header in headers.entries) {
          // see also: https://mpv.io/manual/stable/#list-options （append 接收未转义的单值）。
          arguments.add(
            '--http-header-fields-append=${header.key}: ${header.value}',
          );
        }
        arguments.addAll(['--', spec.url]);
      case ExternalPlayerKind.vlc:
        if (hasPosition) arguments.add('--start-time=${_seconds(position)}');
        var unsupportedHeaders = false;
        for (final header in headers.entries) {
          // see also: https://raw.githubusercontent.com/videolan/vlc/3.0.x/modules/access/http.c
          switch (header.key.toLowerCase()) {
            case 'user-agent':
              arguments.add('--http-user-agent=${header.value}');
            case 'referer':
              arguments.add('--http-referrer=${header.value}');
            default:
              unsupportedHeaders = true;
          }
        }
        if (unsupportedHeaders) {
          warnings.add(
            'VLC 仅支持传递 User-Agent 和 Referer，其余请求头未传递，播放可能失败。',
          );
        }
        arguments.addAll(['--', spec.url]);
    }
    _validateCommandLength(settings.executablePath, arguments);
    return ExternalPlayerLaunchPlan(
      executable: settings.executablePath,
      arguments: arguments,
      warnings: warnings,
    );
  }

  /// true 仅确认进程已启动，不代表媒体已播放。启动成功后即使已过期仍返回 true。
  /// false 表示启动前已取消；调用方须在暂停内部播放器前再次检查会话归属。
  Future<bool> launch(
    ExternalPlayerLaunchPlan plan, {
    bool Function()? isCurrent,
  }) async {
    if (!_mayLaunch(isCurrent)) return false;
    _validateExecutable(plan.executable);
    if (plan.arguments.isEmpty) {
      throw const ExternalPlayerLaunchException('外部播放器启动参数无效。');
    }
    for (final argument in plan.arguments) {
      if (_controlCharacters.hasMatch(argument)) {
        throw const ExternalPlayerLaunchException('外部播放器启动参数包含控制字符。');
      }
    }
    _validateUrl(plan.arguments.last);
    _validateCommandLength(plan.executable, plan.arguments);

    final bool exists;
    try {
      exists = await _fileExists(plan.executable);
    } catch (_) {
      if (!_mayLaunch(isCurrent)) return false;
      throw const ExternalPlayerLaunchException('无法检查外部播放器文件，请检查路径和访问权限。');
    }
    if (!_mayLaunch(isCurrent)) return false;
    if (!exists) {
      throw const ExternalPlayerLaunchException('外部播放器文件不存在，请重新选择可执行文件。');
    }
    try {
      await _start(plan.executable, plan.arguments);
    } catch (_) {
      throw const ExternalPlayerLaunchException('无法启动外部播放器，请检查程序和访问权限。');
    }
    return true;
  }

  void _validateExecutable(String executable) {
    if (!_isWindows) {
      throw const ExternalPlayerLaunchException('外部播放器目前仅支持 Windows。');
    }
    if (_controlCharacters.hasMatch(executable) ||
        !_driveRoot.hasMatch(executable) ||
        !executable.toLowerCase().endsWith('.exe')) {
      throw const ExternalPlayerLaunchException('请选择本机绝对路径下的 .exe 播放器文件。');
    }
    final localPath = executable.substring(3);
    if (_invalidPathCharacters.hasMatch(localPath) ||
        localPath.split(_pathSeparator).any(
              (part) =>
                  part.isEmpty || part.endsWith(' ') || part.endsWith('.'),
            )) {
      throw const ExternalPlayerLaunchException('外部播放器路径格式无效。');
    }
  }

  static void _validateUrl(String url) {
    const error = ExternalPlayerLaunchException(
      '播放地址无效或协议不受支持，请使用已解析的 HTTP、HTTPS、RTSP、RTMP 或 file 地址。',
    );
    if (url.isEmpty || url != url.trim() || _controlCharacters.hasMatch(url)) {
      throw error;
    }
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !_mediaSchemes.contains(uri.scheme)) throw error;
      final schemeEnd = url.indexOf(':');
      final host = Uri.decodeComponent(uri.host);
      if (_hostWhitespace.hasMatch(host) ||
          _controlCharacters.hasMatch(host) ||
          host.contains('\\')) {
        throw error;
      }
      if (uri.scheme == 'file') {
        // invariant: Uri.parse 会将 file:relative 规范化，不能据此接受相对地址。
        if (!url.startsWith('/', schemeEnd + 1) ||
            !uri.path.startsWith('/') ||
            uri.path == '/') {
          throw error;
        }
      } else if (!url.startsWith('//', schemeEnd + 1) ||
          !uri.hasAuthority ||
          host.isEmpty) {
        throw error;
      }
    } on FormatException {
      throw error;
    }
  }

  static bool _mayLaunch(bool Function()? isCurrent) {
    try {
      return isCurrent?.call() ?? true;
    } catch (_) {
      throw const ExternalPlayerLaunchException('无法确认当前播放状态，请重试。');
    }
  }

  static String _seconds(Duration position) {
    final microseconds = position.inMicroseconds;
    final seconds = microseconds ~/ Duration.microsecondsPerSecond;
    final remainder = microseconds % Duration.microsecondsPerSecond;
    if (remainder == 0) return '$seconds';
    final fraction = remainder.toString().padLeft(6, '0').replaceFirst(
          RegExp(r'0+$'),
          '',
        );
    return '$seconds.$fraction';
  }

  static void _validateCommandLength(
    String executable,
    List<String> arguments,
  ) {
    var length = _quotedLength(executable) + 1;
    for (final argument in arguments) {
      length += 1 + _quotedLength(argument);
      if (length > _maxCommandLineCodeUnits) break;
    }
    if (length > _maxCommandLineCodeUnits) {
      throw const ExternalPlayerLaunchException('播放参数过长，无法安全启动外部播放器。');
    }
  }

  /// 按 Windows argv 引号及反斜线转义计算 UTF-16 长度上界，不拼接命令行。
  static int _quotedLength(String value) {
    var length = value.length + 2;
    var backslashes = 0;
    for (final unit in value.codeUnits) {
      if (unit == 0x5c) {
        backslashes++;
      } else {
        if (unit == 0x22) length += backslashes + 1;
        backslashes = 0;
      }
    }
    return length + backslashes;
  }

  static Future<void> _startDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }
}
