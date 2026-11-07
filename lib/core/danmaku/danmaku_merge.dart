import 'dart:typed_data';

import 'danmaku_models.dart';
import 'danmaku_settings.dart';

/// 合并重复弹幕（issue #14，开关见 [DanmakuSettings.mergeDuplicates]）。
///
/// 同类型、同为白色 / 彩色、归一化后文本相同的弹幕，从一组的首条起
/// [DanmakuSettings.mergeWindow] 秒内并成一条：时间、颜色、原文取首条，末尾标「x 条数」
/// （与服务端 danmu_api 按分钟合并的写法一致，服务端已带的「x N」计入条数）。
/// 高级弹幕的文本是脚本，不合并。
///
/// 纯函数：结果只取决于整条轨道（与输入顺序、播放位置无关），所以拖动进度条后上屏的仍是同一批；
/// 在排布器的类型屏蔽 / 密度抽样 / 每秒上限之前做，被并掉的重复不占轨道和配额。
/// 没有可合并的弹幕时原样返回 [track]。实测 4.3 万条约 35 ms、1.8 万条约 14 ms（AOT），
/// 由弹幕层每条轨道只算一次（载入后首次打开开关时）。
DanmakuTrack mergeDuplicateDanmaku(DanmakuTrack track) {
  final items = List.of(track.items);
  _sortTies(items);
  final groups = <_Group>[];
  // 按「类型 × 白色 / 彩色」分桶，桶内以归一化文本为键指向该文本当前所在的组
  final open = [for (var i = 0; i < DanmakuMode.values.length * 2; i++) <String, _Group>{}];
  var merged = false;
  for (final item in items) {
    final (:base, :count) = _parse(item.text);
    if (item.mode == DanmakuMode.advanced) {
      groups.add(_Group(item, base, count));
      continue;
    }
    final bucket = open[item.mode.index * 2 + (_isWhite(item) ? 1 : 0)];
    final key = _core(base);
    final g = bucket[key];
    if (g != null && item.time - g.first.time <= DanmakuSettings.mergeWindow) {
      g.size++;
      g.count += count;
      merged = true;
    } else {
      groups.add(bucket[key] = _Group(item, base, count));
    }
  }
  if (!merged) return track;
  return DanmakuTrack([
    for (final g in groups)
      g.size == 1
          ? g.first
          : DanmakuItem(
              time: g.first.time,
              text: '${g.base}\u200Ax\u200A${g.count}',
              mode: g.first.mode,
              color: g.first.color,
            ),
  ]);
}

class _Group {
  _Group(this.first, this.base, this.count);

  final DanmakuItem first;
  final String base;
  int count;
  int size = 1;
}

/// 轨道已按时间排好，但同一时刻的几条先后不固定：按文本 / 类型 / 颜色排定，结果才与输入顺序无关。
void _sortTies(List<DanmakuItem> items) {
  var i = 0;
  while (i < items.length) {
    var j = i + 1;
    while (j < items.length && items[j].time == items[i].time) {
      j++;
    }
    if (j - i > 1) items.setRange(i, j, items.sublist(i, j)..sort(_order));
    i = j;
  }
}

int _order(DanmakuItem a, DanmakuItem b) {
  var c = a.text.compareTo(b.text);
  if (c != 0) return c;
  c = a.mode.index - b.mode.index;
  return c != 0 ? c : a.color - b.color;
}

bool _isWhite(DanmakuItem item) => (item.color & 0xFFFFFF) == 0xFFFFFF;

// 服务端 danmu_api 拼在末尾的标记（细空格 U+200A 开头）：先合并成「x N」，再拼点赞「🔥1.2k」/「♡8」。
final _likeTail = RegExp('\u200A(?:\u{1F525}|\uFE0F?\u2661)[0-9.]+[wk]?\$');

/// 去掉服务端标记后的原文 + 它代表的条数。
({String base, int count}) _parse(String text) {
  var at = text.lastIndexOf('\u200A');
  if (at < 0) return (base: text, count: 1);
  var base = text;
  if (_likeTail.matchAsPrefix(base, at) != null) {
    base = base.substring(0, at);
    at = base.lastIndexOf('\u200A');
  }
  var count = 1;
  if (at >= 2 && base.codeUnitAt(at - 1) == 0x78 && base.codeUnitAt(at - 2) == 0x200A) {
    final n = _digits(base, at + 1);
    if (n != null) {
      count = n < 1 ? 1 : n;
      base = base.substring(0, at - 2);
    }
  }
  return (base: base.trimRight(), count: count);
}

/// [from] 起到末尾全是数字时的值，否则 null。
int? _digits(String s, int from) {
  if (from >= s.length) return null;
  var n = 0;
  for (var i = from; i < s.length; i++) {
    final c = s.codeUnitAt(i) - 0x30;
    if (c < 0 || c > 9) return null;
    if (n < 1000000) n = n * 10 + c;
  }
  return n;
}

var _buf = Uint32List(64);

/// 归一化：全角转半角、英文小写、去空白，3 个以上相同的字压成 2 个，去掉末尾标点 / 表情
/// （「哈哈哈哈」=「哈哈」，「哈」≠「哈哈」）；全是符号时留一个（「？？？」=「?」）。
String _core(String text) {
  if (_buf.length < text.length) _buf = Uint32List(text.length * 2);
  final buf = _buf;
  var n = 0;
  for (var i = 0; i < text.length; i++) {
    var r = text.codeUnitAt(i);
    if (r >= 0xD800 && r <= 0xDBFF && i + 1 < text.length) {
      final lo = text.codeUnitAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        r = 0x10000 + ((r - 0xD800) << 10) + (lo - 0xDC00);
        i++;
      }
    }
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0;
    if (r == 0x3002 || r == 0xFF61 || r == 0x2026) r = 0x2E; // 。｡… → .
    if (r == 0x3001) r = 0x2C; // 、 → ,
    if (r >= 0x41 && r <= 0x5A) r += 0x20;
    if (r == 0xFE0F || _isSpace(r)) continue;
    if (n >= 2 && buf[n - 1] == r && buf[n - 2] == r) continue;
    buf[n++] = r;
  }
  var end = n;
  while (end > 0 && !_isWord(buf[end - 1])) {
    end--;
  }
  if (end == 0) return n == 0 ? '' : String.fromCharCode(buf[0]);
  return String.fromCharCodes(buf, 0, end);
}

bool _isSpace(int r) =>
    r == 0x20 || (r >= 0x09 && r <= 0x0D) || r == 0xA0 || r == 0x3000 || (r >= 0x2000 && r <= 0x200A) ||
    r == 0x202F || r == 0x205F;

final _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _wordCache = <int, bool>{};

bool _isWord(int r) {
  if (r < 0x80) return (r >= 0x30 && r <= 0x39) || (r >= 0x61 && r <= 0x7A);
  if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3040 && r <= 0x30FF) || (r >= 0xAC00 && r <= 0xD7AF)) return true;
  return _wordCache[r] ??= _letterOrNumber.hasMatch(String.fromCharCode(r));
}
