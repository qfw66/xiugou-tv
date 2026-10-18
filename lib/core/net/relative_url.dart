/// 配置内相对地址还原。
///
/// 真实配置里站点的 `api` / `ext` / `jar` 与全局 `spider` 大量使用相对路径
/// （`./js/drpy2.min.js`、`./jar/top98_1.jar`、`../common/x.py`）。
/// 手机端在配置加载后会对整份文本做 `./`、`../` 替换（`Decoder.fix`），
/// 桌面端此前只对多仓条目做了还原，导致站点侧相对地址无法下载。
class RelativeUrl {
  const RelativeUrl._();

  /// 形如 `scheme://` 的绝对地址不参与还原。
  static final RegExp _absolutePattern =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// 把 [value] 按 [base] 还原为绝对地址；不适用时原样返回。
  ///
  /// [allowBareRelative] 用于区分「必然是路径」的字段（jar / spider）
  /// 与「可能是 URL、也可能是自由文本」的字段（ext，例如 XBPQ 的
  /// `分类url:http://host/{cateId}?...`）。
  static String? resolve(Uri? base, String? value,
      {bool allowBareRelative = false}) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return value;
    if (base == null) return value;

    // JSON 形态的 ext 不是地址
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return value;

    // 已有协议的绝对地址
    if (_absolutePattern.hasMatch(trimmed)) return value;

    // 协议相对地址 `//host/path`
    if (trimmed.startsWith('//')) {
      final scheme = base.scheme.isEmpty ? 'https' : base.scheme;
      return '$scheme:$trimmed';
    }

    if (trimmed.startsWith('./') || trimmed.startsWith('../')) {
      return _safeResolve(base, trimmed) ?? value;
    }

    // 裸相对路径：只在字段必然是路径时还原，且要求没有协议冒号
    if (allowBareRelative && !trimmed.contains(':') && trimmed.contains('/')) {
      return _safeResolve(base, trimmed) ?? value;
    }

    return value;
  }

  static String? _safeResolve(Uri baseUri, String reference) {
    try {
      return baseUri.resolve(reference).toString();
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
