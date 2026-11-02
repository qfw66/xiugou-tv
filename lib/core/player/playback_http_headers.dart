/// 起播时补浏览器请求头（**只在站点没提供时**）。
///
/// 背景：部分源站按 UA 拦非浏览器请求——清单只给一半就断连（实测 py1080p 专线
/// `tcp: ffurl_read returned ...`、以及 `Stream ends prematurely`）。
/// 这里只做兜底：站点 / 爬虫自己给的 header 一律优先，不覆盖。
library;

/// 默认浏览器 UA（Chrome on Windows）。写成常量便于回退与排查。
const String defaultPlaybackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 给播放请求补 `User-Agent` / `Referer`。
///
/// 约束：
/// - 只有 [enabled] 时才动；关闭后完全按站点原始请求头播放。
/// - 只对远程 http(s) 生效：回环 / 局域网（本机网盘代理）不加头。
/// - 大小写不敏感判断是否已存在，已有一律不覆盖。
Map<String, String>? withBrowserHeaderFallbacks(
  Map<String, String>? headers,
  String url, {
  required bool enabled,
}) {
  if (!enabled) return headers;
  final uri = Uri.tryParse(url);
  if (uri == null) return headers;
  if (uri.scheme != 'http' && uri.scheme != 'https') return headers;
  final host = uri.host;
  if (host.isEmpty ||
      host == 'localhost' ||
      host == '::1' ||
      host.startsWith('127.')) {
    return headers;
  }
  final merged = <String, String>{if (headers != null) ...headers};
  bool has(String name) => merged.keys.any((k) => k.toLowerCase() == name);
  if (!has('user-agent')) merged['User-Agent'] = defaultPlaybackUserAgent;
  if (!has('referer')) {
    final port = uri.hasPort ? ':${uri.port}' : '';
    merged['Referer'] = '${uri.scheme}://${uri.host}$port/';
  }
  return merged;
}
