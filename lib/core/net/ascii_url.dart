/// 国际化域名（IDN）转 ASCII 主机名。
///
/// Dart 的 `Uri` 不会做 IDNA 处理：`Uri.parse('http://饭太硬.cc/tv').host`
/// 得到的是百分号编码的 `%E9%A5%AD...`，而 `HttpClient` 与 dio 都拒绝带 `%`
/// 的 host（`is not a valid link-local address but contains %`）。
/// 手机端 okhttp 的 `HttpUrl` 会自动转 punycode，本模块补齐这一差异。
///
/// 实现 RFC 3492 的 punycode 编码（IDNA 的 ASCII 兼容形式 `xn--`）。
class AsciiUrl {
  const AsciiUrl._();

  /// 返回 host 已转为 ASCII（punycode）的 URL；无 IDN 时原样返回。
  ///
  /// 输入可能来自 `Uri.toString()`，此时中文 host 已被百分号编码
  /// （`www.%E9%A5%AD%E5%A4%AA%E7%A1%AC.cc`），因此不能只检查字符串里
  /// 有无非 ASCII 字符，必须逐个标签还原后再判断。
  static String toAsciiHost(String url) {
    if (url.isEmpty) return url;
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed;

    final asciiHost = _asciiHost(uri.host);
    if (asciiHost == uri.host) return trimmed;

    // Uri.replace 在 host 含 '%' 时会抛错，因此按组件重建。
    try {
      return Uri(
        scheme: uri.scheme,
        userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
        host: asciiHost,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
        query: uri.hasQuery ? uri.query : null,
        fragment: uri.hasFragment ? uri.fragment : null,
      ).toString();
    } on FormatException {
      return trimmed;
    } on ArgumentError {
      return trimmed;
    }
  }

  /// 按标签逐个转换：ASCII 标签保留原样，含非 ASCII 的标签加 `xn--` 前缀。
  static String _asciiHost(String host) {
    // host 可能形如 `www.%E9%A5%AD%E5%A4%AA%E7%A1%AC.cc`，需先还原成 Unicode。
    final labels = host.split('.');
    final converted = <String>[];
    for (final label in labels) {
      final decoded = _decodeLabel(label);
      if (_hasNonAscii(decoded)) {
        converted.add('xn--${punycodeEncode(decoded.toLowerCase())}');
      } else {
        converted.add(decoded);
      }
    }
    return converted.join('.');
  }

  static String _decodeLabel(String label) {
    if (!label.contains('%')) return label;
    try {
      return Uri.decodeComponent(label);
    } on ArgumentError {
      return label;
    } on FormatException {
      return label;
    }
  }

  static bool _hasNonAscii(String value) {
    for (final code in value.codeUnits) {
      if (code > 0x7F) return true;
    }
    return false;
  }
}

const int _base = 36;
const int _tmin = 1;
const int _tmax = 26;
const int _skew = 38;
const int _damp = 700;
const int _initialBias = 72;
const int _initialN = 128;
const String _delimiter = '-';

/// RFC 3492 编码：把含非 ASCII 的字符串转为 punycode 负载（**不含** `xn--` 前缀，
/// 前缀由 [AsciiUrl] 按标签添加）。
///
/// 纯 ASCII 输入原样返回：IDNA 不会给纯 ASCII 标签加 `xn--`，且 RFC 3492 在
/// 无扩展码点时追加的尾分隔符对调用方没有意义。
String punycodeEncode(String input) {
  final codePoints = input.runes.toList();
  if (codePoints.every((cp) => cp < _initialN)) return input;

  final output = StringBuffer();

  final basic = codePoints.where((cp) => cp < _initialN).toList();
  for (final cp in basic) {
    output.writeCharCode(cp);
  }
  var handled = basic.length;
  if (handled > 0) output.write(_delimiter);

  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;

  while (handled < codePoints.length) {
    var m = _maxInt;
    for (final cp in codePoints) {
      if (cp >= n && cp < m) m = cp;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final cp in codePoints) {
      if (cp < n) delta++;
      if (cp != n) continue;
      var q = delta;
      for (var k = _base;; k += _base) {
        final t = k <= bias ? _tmin : (k >= bias + _tmax ? _tmax : k - bias);
        if (q < t) break;
        output.writeCharCode(_digitToChar(t + (q - t) % (_base - t)));
        q = (q - t) ~/ (_base - t);
      }
      output.writeCharCode(_digitToChar(q));
      bias = _adapt(delta, handled + 1, handled == basic.length);
      delta = 0;
      handled++;
    }
    delta++;
    n++;
  }
  return output.toString();
}

int _adapt(int delta, int numPoints, bool firstTime) {
  delta = firstTime ? delta ~/ _damp : delta ~/ 2;
  delta += delta ~/ numPoints;
  var k = 0;
  while (delta > ((_base - _tmin) * _tmax) ~/ 2) {
    delta ~/= _base - _tmin;
    k += _base;
  }
  return k + (((_base - _tmin + 1) * delta) ~/ (delta + _skew));
}

int _digitToChar(int digit) => digit < 26 ? 0x61 + digit : 0x30 + digit - 26;

const int _maxInt = 0x7FFFFFFF;
