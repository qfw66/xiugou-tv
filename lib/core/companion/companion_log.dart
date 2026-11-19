import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/error_log.dart';
import '../storage/data_directory_manager.dart';

/// companion（站源服务）诊断日志：把进程生命周期、stderr 关键行与自愈结果落到
/// 用户数据目录的 `companion.log`，用户回报问题时可以直接把文件发过来。
///
/// 约定：
/// - 只写**关键行**（就绪端口、退出、stderr 折叠后的有意义行、自愈决策），不是全量控制台镜像；
/// - 单文件滚动上限 [maxBytes]（默认 2 MB），超出时旧文件改名为 `companion.log.1`，
///   只保留一份备份，总占用有界；
/// - 每行都过 [ErrorLog.redact] 脱敏（cookie / token / 密码不会落盘）；
/// - 任何 IO 失败都静默吞掉：日志永远不能影响播放与登录。
class CompanionLog {
  CompanionLog({
    this.pathOverride,
    this.maxBytes = defaultMaxBytes,
    this.maxLineLength = 4000,
    String Function(String text)? redact,
  }) : _redact = redact ?? ErrorLog.redact;

  /// 默认单文件上限：2 MB，够放几次完整会话，又不会长期涨。
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  /// 日志文件名（位于用户数据目录，见 [DataDirectoryManager.currentPath]）。
  static const String fileName = 'companion.log';

  static final CompanionLog _shared = CompanionLog();

  /// 应用级日志：与 `CompanionProcessManager()` 单例配套。
  static CompanionLog shared() => _shared;

  /// 默认落盘路径：`<用户数据目录>/companion.log`。
  static String defaultPath() =>
      p.join(DataDirectoryManager.currentPath, fileName);

  /// 显式路径（测试注入）；为 null 时用 [defaultPath]。
  final String? pathOverride;
  final String Function(String text) _redact;

  /// 单文件上限（字节）。
  final int maxBytes;

  /// 单行上限：异常堆栈里的超长行会被截断，避免一行吃掉整个上限。
  final int maxLineLength;

  /// 实际写入路径（每次读取，用户随时可以改数据目录）。
  String get path => pathOverride ?? defaultPath();

  /// 滚动备份路径；有内容被滚动过时该文件存在。
  String get rotatedPath => '$path.1';

  /// 当前文件大小（字节）；不存在时 0。
  int get sizeBytes {
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 追加一行；[message] 里可以带换行（会按行拆分，每行都带时间戳）。
  void write(String message) {
    final text = _format(message);
    if (text.isEmpty) return;
    try {
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      _rotateIfNeeded(utf8.encode(text).length);
      file.writeAsStringSync(text, mode: FileMode.append, flush: false);
    } catch (_) {
      // 日志失败不影响主流程（只读盘 / 目录被占用 / 权限不足都可能发生）
    }
  }

  String _format(String message) {
    final buffer = StringBuffer();
    for (final raw in message.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      final clipped =
          line.length <= maxLineLength ? line : '${line.substring(0, maxLineLength)}…（已截断）';
      buffer.writeln('${DateTime.now().toIso8601String()} ${_redact(clipped)}');
    }
    return buffer.toString();
  }

  /// 写入前保证「当前文件 + 本次内容」不超过 [maxBytes]；超了就把当前文件躺成 `.1`。
  void _rotateIfNeeded(int incomingBytes) {
    if (incomingBytes <= 0) return;
    final size = sizeBytes;
    if (size == 0 || size + incomingBytes <= maxBytes) return;
    final file = File(path);
    final backup = File(rotatedPath);
    try {
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    } catch (_) {
      // 改名失败（文件被占用等）：退化成清空，保证不会无限增长
      try {
        file.writeAsStringSync('', flush: false);
      } catch (_) {}
    }
  }
}
