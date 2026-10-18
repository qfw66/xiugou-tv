import 'dart:convert';

import 'lenient_json.dart';

/// 配置原文解码：对齐手机端 `api/Decoder.java` 的 `verify` 流程。
///
/// 手机端能加载的配置里存在多种 PC 端早期不支持的载体：
/// 1. `<pre>` 包裹的 HTML 页面（PC 端既有能力，保留）
/// 2. 标准 JSON（含宽松写法：注释、无引号 key/值、尾随逗号）
/// 3. `XXXXXXXX**<Base64>` 私有编码（手机端 `Decoder.base64`）
/// 4. 整体 Base64（PC 端既有能力，保留）
///
/// 返回解析后的 JSON 树（Map / List）；全部路径失败时返回 null。
class ConfigDecoder {
  const ConfigDecoder._();

  static final RegExp _prePattern =
      RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false);

  /// 手机端标记位：8 位字母数字 + `**`，标记之后偏移 10 开始是 Base64。
  static final RegExp _markerPattern = RegExp(r'[A-Za-z0-9]{8}\*\*');

  static dynamic decode(String? content) {
    if (content == null) return null;
    var text = content.trim();
    if (text.isEmpty) return null;

    final pre = _prePattern.firstMatch(text);
    if (pre != null) {
      final inner = pre.group(1)?.trim();
      if (inner != null && inner.isNotEmpty) text = inner;
    }

    return _structure(_tryStrict(text)) ??
        _structure(_tryMarkerBase64(text)) ??
        _structure(LenientJson.tryParse(text)) ??
        _structure(_tryWholeBase64(text));
  }

  /// 配置必须是对象或数组；裸标量（含整体 Base64 正文）不构成配置。
  static dynamic _structure(dynamic value) =>
      value is Map || value is List ? value : null;

  /// 去掉 `<pre>` 包裹并返回用于持久化的原文；未命中时返回 null。
  static String? unwrapPre(String content) {
    final pre = _prePattern.firstMatch(content);
    final inner = pre?.group(1)?.trim();
    return inner == null || inner.isEmpty ? null : inner;
  }

  static dynamic _tryStrict(String text) {
    if (!text.startsWith('{') && !text.startsWith('[')) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// 手机端 `Decoder.base64`：标记（8 位 + `**`，共 10 字符）之后即 Base64 负载。
  static dynamic _tryMarkerBase64(String text) {
    final marker = _markerPattern.firstMatch(text);
    if (marker == null) return null;
    final payload =
        text.substring(marker.end).replaceAll(RegExp(r'\s+'), '');
    if (payload.isEmpty) return null;
    try {
      final decoded = utf8.decode(base64Decode(payload), allowMalformed: true);
      return _tryStrict(decoded) ?? LenientJson.tryParse(decoded);
    } catch (_) {
      return null;
    }
  }

  static dynamic _tryWholeBase64(String text) {
    final normalized =
        text.replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
    if (normalized.isEmpty) return null;
    try {
      final decoded = utf8.decode(base64Decode(normalized));
      return _tryStrict(decoded) ?? LenientJson.tryParse(decoded);
    } catch (_) {
      return null;
    }
  }
}
