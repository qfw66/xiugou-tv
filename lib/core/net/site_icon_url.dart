import 'dart:convert';

/// 只接受站源明确声明的图片地址；相对路径留给有确切基址的调用方还原。
String? siteIconReference(Object? value) {
  if (value is! String || value.length > 8 * 1024 * 1024) return null;
  final text = value.trim();
  if (text.isEmpty || text == 'null' || text == 'undefined') return null;
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme == 'data') {
    final comma = text.indexOf(',');
    if (comma < 0 ||
        !RegExp(r'^data:image/[a-z0-9.+-]+;base64$', caseSensitive: false)
            .hasMatch(text.substring(0, comma))) {
      return null;
    }
    try {
      final bytes = base64Decode(text.substring(comma + 1));
      return bytes.isEmpty || bytes.length > 6 * 1024 * 1024 ? null : text;
    } on FormatException {
      return null;
    }
  }
  if (RegExp(r'[\s\\\x00-\x1f\x7f]').hasMatch(text) ||
      RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(text)) {
    return null;
  }
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    return uri.host.isEmpty || uri.userInfo.isNotEmpty ? null : text;
  }
  if (uri.scheme == 'file') {
    return text.toLowerCase().startsWith('file:/') &&
            uri.path.startsWith('/') &&
            !uri.hasQuery &&
            !uri.hasFragment
        ? text
        : null;
  }
  if (uri.hasScheme || uri.path.isEmpty) return null;
  if (uri.hasAuthority && uri.host.isEmpty) return null;
  return text;
}

/// 配置图标以最终配置地址为基址；首页图标以实际响应端点或显式 siteurl 为基址。
/// 无可靠基址的相对图标保持缺省，不拼接 favicon 或试探其他地址。
String? resolveSiteIconUrl(Object? value, {String? baseUrl}) {
  final reference = siteIconReference(value);
  if (reference == null) return null;
  final uri = Uri.parse(reference);
  if (uri.hasScheme) return reference;
  final base = Uri.tryParse(baseUrl?.trim() ?? '');
  if (base == null ||
      !((base.scheme == 'http' || base.scheme == 'https') &&
              base.host.isNotEmpty ||
          base.scheme == 'file' && base.path.startsWith('/'))) {
    return null;
  }
  try {
    return siteIconReference(base.resolveUri(uri).toString());
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// TVBox 首页的 siteicon；Jar 站源可用响应里的 siteurl 明确提供网站基址。
String? parseHomeSiteIcon(Map<String, dynamic> json, {String? baseUrl}) {
  final declaredBase = json['siteurl'];
  final siteUri =
      declaredBase is String ? Uri.tryParse(declaredBase.trim()) : null;
  final siteBase = siteUri != null &&
          (siteUri.scheme == 'http' || siteUri.scheme == 'https') &&
          siteUri.host.isNotEmpty
      ? declaredBase as String
      : baseUrl;
  return resolveSiteIconUrl(json['siteicon'], baseUrl: siteBase);
}
