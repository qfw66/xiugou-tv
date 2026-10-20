/// ④ 直播播放报错诊断闭环 · 纯逻辑层。
///
/// 三类可复用能力（全部纯函数 / 独立数据结构，单测直接钉住）：
/// 1. 脱敏：URL 与请求头里的敏感字段（token / auth / sign …）打码；
/// 2. 诊断文本：把「原始错误 + 脱敏地址 + 请求头概览 + 引擎日志」拼成
///    可复制文本（复制是用户主动行为，但文本仍不携带未脱敏的密钥）；
/// 3. 引擎日志环形缓冲：只保留最近 [RecentLogBuffer.capacity] 条（④ 定 40）。
library;

import 'models/player_state.dart';

/// 敏感字段名：命中（不区分大小写）的 query 参数 / 请求头，其值整体打码。
final RegExp sensitiveFieldPattern = RegExp(
  r'(token|auth|key|sign|secret|pwd|password|credential|expire)',
  caseSensitive: false,
);

/// URL 脱敏：隐藏 userinfo（`user:pass@`）与敏感 query 值；
/// 其余（id、清晰度等排查必需信息）保持原样。
///
/// 字符串级替换（不走 `Uri.replace`）：不改动 URL 其余部分、不做百分号
/// 重编码，也不受非常规地址形态影响。
String maskSensitiveUrl(String url) {
  var result = url;
  // 敏感 query 值：键名与 [sensitiveFieldPattern] 同源，值整体打码。
  result = result.replaceAllMapped(
    RegExp(
      r'([?&](?:token|auth|key|sign|secret|pwd|password|credential|expire)[^=&#]*=)[^&#]*',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}***',
  );
  // userinfo：user:pass@ → ***@
  result = result.replaceAllMapped(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]+@'),
    (match) => '${match.group(1)}***@',
  );
  return result;
}

/// 请求头脱敏：只对敏感名（Authorization / Cookie / 带 token 的自定义头）
/// 打码；Referer / User-Agent 保留——它们是排查防盗链问题的关键线索。
Map<String, String> maskSensitiveHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return const {};
  return {
    for (final entry in headers.entries)
      entry.key:
          sensitiveFieldPattern.hasMatch(entry.key) ? '***' : entry.value,
  };
}

/// 日志脱敏：把日志里出现的完整地址替换为脱敏版，并抹掉敏感请求头的值
/// （mpv 日志会打印打开的 URL 与部分请求头）。
List<String> maskLogLines(
  List<String> lines, {
  String? rawUrl,
  String? maskedUrl,
  Map<String, String>? rawHeaders,
}) {
  var result = lines;
  if (rawUrl != null && rawUrl.isNotEmpty && maskedUrl != null) {
    result = [for (final line in result) line.replaceAll(rawUrl, maskedUrl)];
  }
  if (rawHeaders != null) {
    for (final entry in rawHeaders.entries) {
      if (sensitiveFieldPattern.hasMatch(entry.key) &&
          entry.value.length >= 4) {
        result = [
          for (final line in result) line.replaceAll(entry.value, '***')
        ];
      }
    }
  }
  return result;
}

/// 对任意单段文本做「URL + 敏感头值」脱敏（原始错误 / 日志行复用）。
String maskDiagnosticText(
  String text, {
  String? rawUrl,
  String? maskedUrl,
  Map<String, String>? rawHeaders,
}) =>
    maskLogLines([text],
            rawUrl: rawUrl, maskedUrl: maskedUrl, rawHeaders: rawHeaders)
        .first;

/// 引擎日志环形缓冲（固定容量，超出丢最旧）。
class RecentLogBuffer {
  RecentLogBuffer({this.capacity = 40});

  final int capacity;
  final List<String> _entries = [];

  List<String> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  void add(String line) {
    _entries.add(line);
    final overflow = _entries.length - capacity;
    if (overflow > 0) _entries.removeRange(0, overflow);
  }

  void clear() => _entries.clear();
}

/// 拼装「复制诊断」文本。所有 URL / 请求头先脱敏；日志中的完整地址与
/// 敏感请求头值也会被替换（不把密钥带进用户要分享出去的文本里）。
String buildPlaybackDiagnosticText({
  required String? rawError,
  required MediaPlaySpec? spec,
  required List<String> engineLogs,
  DateTime? now,
}) {
  final maskedUrl = spec == null ? null : maskSensitiveUrl(spec.url);
  final headers = maskSensitiveHeaders(spec?.headers);
  final logs = maskLogLines(
    engineLogs,
    rawUrl: spec?.url,
    maskedUrl: maskedUrl,
    rawHeaders: spec?.headers,
  );

  final buffer = StringBuffer('[修狗TV] 播放诊断信息')..writeln();
  buffer.writeln('时间: ${(now ?? DateTime.now()).toIso8601String()}');
  final title = spec?.title;
  if (title != null && title.isNotEmpty) {
    buffer.writeln('影片: $title');
  }
  buffer.writeln('直播: ${spec?.isLive == true ? '是' : '否'}');
  final raw = rawError?.trim() ?? '';
  final rawMasked = raw.isEmpty
      ? ''
      : maskDiagnosticText(raw,
          rawUrl: spec?.url, maskedUrl: maskedUrl, rawHeaders: spec?.headers);
  buffer.writeln('原始错误: ${rawMasked.isEmpty ? '(空)' : rawMasked}');
  buffer.writeln('地址: ${maskedUrl ?? '(无)'}');
  if (headers.isEmpty) {
    buffer.writeln('请求头: (无)');
  } else {
    buffer.writeln('请求头:');
    for (final entry in headers.entries) {
      buffer.writeln('  ${entry.key}: ${entry.value}');
    }
  }
  buffer.writeln('引擎日志（最近 ${logs.length} 条）:');
  if (logs.isEmpty) {
    buffer.writeln('  (无)');
  } else {
    for (final line in logs) {
      buffer.writeln('  $line');
    }
  }
  return buffer.toString();
}
