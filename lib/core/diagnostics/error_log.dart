import 'package:flutter/foundation.dart';

/// 错误日志（设置 → 关于 → 「错误日志」：点击在应用内查看，长按清除）。
///
/// 2026-10-27 用户口径：**只记录本次打开期间**的错误，软件关闭即清空——
/// 所以只放内存，不写磁盘；最多保留 [maxEntries] 条（超出丢最旧的）。
///
/// 记录内容：时间、来源（界面 / 未捕获异常 / 播放器…）、摘要、截断的堆栈。
/// 订阅地址的查询串、令牌 / Authorization / Cookie 等经 [redact] 抹掉。
class ErrorLogEntry {
  const ErrorLogEntry({required this.time, required this.source, required this.message, this.stack});

  final DateTime time;
  final String source;
  final String message;
  final String? stack;

  String get timeText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  @override
  String toString() =>
      '[$timeText] $source · $message${stack == null ? '' : '\n${stack!.split('\n').map((l) => '    $l').join('\n')}'}';
}

class ErrorLog extends ChangeNotifier {
  ErrorLog({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<ErrorLogEntry> _entries = [];

  static const int maxEntries = 200;
  static const int maxStackLines = 30;

  /// 全局实例（应用生命周期内一份）。
  static final ErrorLog instance = ErrorLog();

  List<ErrorLogEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;

  void record(String source, Object error, [StackTrace? stack]) {
    String? stackText;
    if (stack != null) {
      final lines = '$stack'.trimRight().split('\n').where((l) => l.trim().isNotEmpty).toList();
      stackText = [
        ...lines.take(maxStackLines).map((l) => l.trimRight()),
        if (lines.length > maxStackLines) '…（其余 ${lines.length - maxStackLines} 行已省略）',
      ].join('\n');
    }
    _entries.add(ErrorLogEntry(time: _now(), source: source, message: redact('$error').trim(), stack: stackText));
    if (_entries.length > maxEntries) _entries.removeRange(0, _entries.length - maxEntries);
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 全部内容（复制用）。
  String get text => _entries.map((e) => e.toString()).join('\n\n');

  /// 抹掉 URL 查询串与常见凭据字段，避免令牌进日志。
  static String redact(String text) => text
      .replaceAllMapped(RegExp(r'(https?://[^\s?#"]+)\?[^\s"]*'), (m) => '${m[1]}?…')
      .replaceAllMapped(
          // Authorization: Bearer xxx —— 认证方案后面的值一起抹掉
          RegExp(r'((?:token|authorization|cookie|password|passwd|secret)\s*[=:]\s*)(?:(?:bearer|basic)\s+)?[^\s,;&]+',
              caseSensitive: false),
          (m) => '${m[1]}…');
}
