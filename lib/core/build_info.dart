import 'dart:io';

import 'package:flutter/foundation.dart';

/// 构建信息（设置 → 关于：「Build Time」「Commit Hash」）。
///
/// - 打包：`scripts/build_windows.ps1` 用 `--dart-define` 注入
///   `XIUGOU_BUILD_TIME`（本地时间 `yyyy-MM-dd HH:mm:ss`）与 `XIUGOU_COMMIT`（短哈希，工作区有改动时带 `-dirty`）；
/// - 开发态（debug / profile，且不是 `flutter test`）编译期没注入时，现场读 `git` 补上，
///   时间显示为「开发版本」，不冒充某次构建；
/// - 都拿不到时显示「未知」。
abstract final class BuildInfo {
  static const String _compiledTime = String.fromEnvironment('XIUGOU_BUILD_TIME');
  static const String _compiledCommit = String.fromEnvironment('XIUGOU_COMMIT');

  static String? _devCommit;
  static bool _devResolved = false;

  static String get buildTime {
    if (_compiledTime.isNotEmpty) return _compiledTime;
    return _devAllowed ? '开发版本' : '未知';
  }

  static String get commit {
    if (_compiledCommit.isNotEmpty) return _compiledCommit;
    if (!_devAllowed) return '未知';
    if (!_devResolved) {
      _devResolved = true;
      _devCommit = _readGitCommit();
    }
    return _devCommit ?? '未知';
  }

  static bool get _devAllowed => !kReleaseMode && Platform.environment['FLUTTER_TEST'] != 'true';

  static String? _readGitCommit() {
    try {
      final r = Process.runSync('git', ['rev-parse', '--short=8', 'HEAD']);
      if (r.exitCode != 0) return null;
      final hash = '${r.stdout}'.trim();
      if (hash.isEmpty) return null;
      final dirty = Process.runSync('git', ['status', '--porcelain', '--untracked-files=no']);
      return '${dirty.stdout}'.trim().isEmpty ? hash : '$hash-dirty';
    } catch (_) {
      return null;
    }
  }
}
