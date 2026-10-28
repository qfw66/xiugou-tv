import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 构建期私有配置（§43 / §44）：弹幕服务、共享片段服务的地址与令牌。
///
/// **谁会用到**：只有项目维护者。普通用户直接用维护者打包好的安装包，界面上看不到、也不需要配置这些。
/// 其他开发者拿仓库代码自行构建时，可以不配置，相关可选功能就不出现，其余功能不受影响。
///
/// 取值顺序：
/// 1. 编译期注入（`--dart-define-from-file=config/app.env`；`scripts/build_windows.ps1` 自动带上）——
///    **发布包只认这一项**；
/// 2. 仅开发态（debug / profile，且不是 `flutter test`）：编译期没注入时，读项目根目录的
///    `config/app.env`。这样维护者 `flutter run`（带不带其它 `--dart-define` 都行）不用每次手动加参数。
///
/// `config/app.env` 已被 `.gitignore` 排除，不会进仓库；模板见 `config/app.env.example`。
abstract final class AppEnv {
  // String.fromEnvironment 的键必须是常量，所以每个键单独写一行。
  static const Map<String, String> _compiled = {
    'XIUGOU_DANMAKU_URL': String.fromEnvironment('XIUGOU_DANMAKU_URL'),
    'XIUGOU_DANMAKU_TOKEN': String.fromEnvironment('XIUGOU_DANMAKU_TOKEN'),
    'XIUGOU_SEGMENTS_URL': String.fromEnvironment('XIUGOU_SEGMENTS_URL'),
    'XIUGOU_SEGMENTS_TOKEN': String.fromEnvironment('XIUGOU_SEGMENTS_TOKEN'),
  };

  static Map<String, String>? _devFile;

  /// 读取一项配置；都没有时返回空串。
  static String get(String key) {
    final compiled = _compiled[key] ?? '';
    if (compiled.isNotEmpty) return compiled;
    if (!_devFallbackAllowed) return '';
    return (_devFile ??= _readDevFile())[key] ?? '';
  }

  /// 发布包（release）不读磁盘文件；`flutter test` 也不读，保证测试环境稳定为「未配置」。
  static bool get _devFallbackAllowed =>
      !kReleaseMode && Platform.environment['FLUTTER_TEST'] != 'true';

  static Map<String, String> _readDevFile() {
    try {
      final file = File('${Directory.current.path}${Platform.pathSeparator}config'
          '${Platform.pathSeparator}app.env');
      if (!file.existsSync()) return const {};
      return parseEnv(file.readAsStringSync());
    } catch (_) {
      return const {};
    }
  }

  /// 解析 `.env` 文本（与 `--dart-define-from-file` 同口径）：`KEY=VALUE`，`#` 开头为注释；
  /// 值可用单 / 双引号包裹（引号内的 `#` 保留），不加引号时 ` #` 之后视为注释。
  @visibleForTesting
  static Map<String, String> parseEnv(String text) {
    final out = <String, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq).trim();
      var value = line.substring(eq + 1).trim();
      if (value.length >= 2 &&
          (value[0] == '"' || value[0] == "'") &&
          value.indexOf(value[0], 1) > 0) {
        value = value.substring(1, value.indexOf(value[0], 1));
      } else {
        final hash = value.indexOf('#');
        if (hash >= 0) value = value.substring(0, hash).trim();
      }
      out[key] = value;
    }
    return out;
  }
}

