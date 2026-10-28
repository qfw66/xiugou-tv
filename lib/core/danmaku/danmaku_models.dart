import 'dart:convert';

/// 弹幕显示位置（对应 B 站 / dandanplay 的 mode：1/2/3 滚动、4 底部、5 顶部；
/// 6 逆向滚动、7 定位、8 代码等特殊类型统称 [advanced]，桌面端按滚动画、默认屏蔽）。
enum DanmakuMode { scroll, top, bottom, advanced }

/// 单条弹幕。时间单位秒，颜色为 0xRRGGBB。
class DanmakuItem implements Comparable<DanmakuItem> {
  const DanmakuItem({
    required this.time,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.color = 0xFFFFFF,
  });

  final double time;
  final String text;
  final DanmakuMode mode;
  final int color;

  @override
  int compareTo(DanmakuItem other) => time.compareTo(other.time);

  @override
  String toString() => 'DanmakuItem($time, $mode, #${color.toRadixString(16)}, $text)';
}

/// 弹幕服务给出的一个匹配候选（`/danmaku` 接口的一项）。
class DanmakuCandidate {
  const DanmakuCandidate({required this.name, required this.url});

  /// 形如「醉梦(2026)【国产剧】from tencent - 【qq】 醉梦 第1集 …」
  final String name;

  /// 取弹幕地址（服务端给的是 `?format=xml`，客户端统一换成 json）
  final String url;

  /// 统一请求 JSON：体积比 XML 小、解析快。
  String get jsonUrl {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final query = Map<String, String>.of(uri.queryParameters)..['format'] = 'json';
    return uri.replace(queryParameters: query).toString();
  }

  static List<DanmakuCandidate> listFromJson(Object? decoded) {
    if (decoded is! List) return const [];
    final out = <DanmakuCandidate>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final name = e['name']?.toString() ?? '';
      final url = e['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      out.add(DanmakuCandidate(name: name, url: url));
    }
    return out;
  }
}

/// 一集的弹幕数据（按时间升序）。
class DanmakuTrack {
  DanmakuTrack(List<DanmakuItem> items) : items = List.unmodifiable(items..sort());

  final List<DanmakuItem> items;

  int get length => items.length;
  bool get isEmpty => items.isEmpty;

  /// 第一条 `time >= t` 的下标（二分）；全部早于 t 时返回 [length]。
  int lowerBound(double t) {
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].time < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 解析弹幕服务（LogVar Danmu API / dandanplay 兼容）的 JSON：
  /// `{"count":N,"comments":[{"cid":1,"p":"秒,模式,颜色[,来源]","m":"文本"}]}`。
  ///
  /// 容错：`p` 字段缺失 / 非法的条目跳过；模式只认 1/4/5（2、3 等滚动变体按滚动）；
  /// 文本去掉零宽字符与首尾空白，空文本跳过。
  static DanmakuTrack fromJson(Object? decoded) {
    final comments = decoded is Map ? decoded['comments'] : decoded;
    if (comments is! List) return DanmakuTrack(<DanmakuItem>[]);
    final out = <DanmakuItem>[];
    for (final c in comments) {
      if (c is! Map) continue;
      final item = _parse(c['p']?.toString(), c['m']?.toString());
      if (item != null) out.add(item);
    }
    return DanmakuTrack(out);
  }

  static DanmakuTrack fromJsonString(String body) => fromJson(jsonDecode(body));

  static final RegExp _invisible = RegExp('[\u200b-\u200f\u2060\ufeff]');

  static DanmakuItem? _parse(String? p, String? m) {
    if (p == null || m == null) return null;
    final parts = p.split(',');
    if (parts.isEmpty) return null;
    final time = double.tryParse(parts[0].trim());
    if (time == null || !time.isFinite || time < 0) return null;
    final text = m.replaceAll(_invisible, '').trim();
    if (text.isEmpty) return null;
    final modeCode = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
    final mode = switch (modeCode) {
      4 => DanmakuMode.bottom,
      5 => DanmakuMode.top,
      6 || 7 || 8 || 9 => DanmakuMode.advanced,
      _ => DanmakuMode.scroll,
    };
    final rawColor = parts.length > 2 ? int.tryParse(parts[2].trim()) : null;
    final color = rawColor == null || rawColor < 0 ? 0xFFFFFF : rawColor & 0xFFFFFF;
    return DanmakuItem(time: time, text: text, mode: mode, color: color);
  }
}
