import 'dart:math';

import 'models/vod_models.dart';

/// 「评分盲开」拿不到评分候选（网络失败 / 榜单为空）。
///
/// 单独一种错误是为了让界面直接显示一句中文原因，而不是把底层网络异常原文丢给用户。
class RatingPickUnavailable implements Exception {
  const RatingPickUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次「评分盲开」的结果：挑中的影片 + 它的评分（界面用来提示「盲开：《X》 8.9 分」）。
class RatingPick {
  const RatingPick({required this.item, required this.score});

  final VodItem item;

  /// 10 分制评分，已由 [parseRating] 解析过（一定 > 0）。
  final double score;

  /// 展示用评分文案（固定一位小数，与豆瓣口径一致）。
  String get scoreText => score.toStringAsFixed(1);
}

/// 把站源 / 豆瓣的评分字符串解析成 10 分制分数。
///
/// 站源常见写法：`8.7`、`8.7分`、`9`、` 7.5 `；豆瓣走同一条（[DoubanRepository] 内部
/// 已 `toStringAsFixed(1)`）。`null`、空串、`0`、非数字、超出 0–10 一律视为「没有评分」。
double? parseRating(String? raw) {
  final text = (raw ?? '').replaceAll('分', '').trim();
  if (text.isEmpty) return null;
  final value = double.tryParse(text);
  if (value == null || value <= 0 || value > 10) return null;
  return value;
}

/// 盲开去重键：站源 + 条目 id + 片名。
///
/// 豆瓣条目没有 siteKey，所以同一部片出现在多个榜单（Top250 / 热播）里时键相同，
/// 只会作为一部候选参与随机。
String ratingKeyOf(VodItem item) =>
    '${item.siteKey ?? ''}|${item.id}|${item.name}';

/// 「评分盲开」的挑片逻辑：从候选里按评分随机挑一部。
///
/// 纯逻辑：不碰网络、不碰 UI，随机源从构造函数注入（测试用固定 seed 即可复现）。
///
/// 规则（按这个顺序）：
/// 1. 只留**有评分**的条目（见 [parseRating]），并按 [ratingKeyOf] 去重；
/// 2. 避开最近 [recentLimit] 部刚挑过的片；全被避开时退回全体——
///    宁可重复，也不能让按钮点了没反应；
/// 3. **评分优先**：只在「最高分往下 [scoreBand] 分以内」的条目里抽；
/// 4. 这个区间内等概率随机：评分接近的片机会均等，盲开才有惊喜，也不会部部都是
///    榜首那一部。
class RatingPicker {
  RatingPicker({
    Random? random,
    this.recentLimit = 8,
    this.scoreBand = 0.8,
  })  : assert(recentLimit >= 0, 'recentLimit 不能为负'),
        assert(scoreBand >= 0, 'scoreBand 不能为负'),
        _random = random ?? Random();

  /// 最近挑过的片数（去重窗口）。
  final int recentLimit;

  /// 优质区间宽度：只抽「最高分 - scoreBand」以上的片。
  final double scoreBand;

  final Random _random;

  /// 最近挑过的去重键，最近的在最前，长度不超过 [recentLimit]。
  final List<String> _recent = <String>[];

  /// 最近挑过的去重键（最近的在最前），只读副本，供调试与测试。
  List<String> get recent => List<String>.unmodifiable(_recent);

  /// 清空去重窗口（换站源 / 换候选来源时调用，避免旧记录挡住新候选）。
  void reset() => _recent.clear();

  /// 挑一部片；**没有任何带评分的候选时返回 null**（由界面提示「暂无评分数据」）。
  RatingPick? pick(Iterable<VodItem> candidates) {
    final rated = <String, ({VodItem item, double score})>{};
    for (final item in candidates) {
      final score = parseRating(item.score);
      if (score == null) continue;
      rated.putIfAbsent(ratingKeyOf(item), () => (item: item, score: score));
    }
    if (rated.isEmpty) return null;

    final fresh = <({VodItem item, double score})>[
      for (final entry in rated.entries)
        if (!_recent.contains(entry.key)) entry.value,
    ];
    final pool = fresh.isEmpty ? rated.values.toList() : fresh;

    var best = 0.0;
    for (final entry in pool) {
      best = max(best, entry.score);
    }
    final band = <({VodItem item, double score})>[
      for (final entry in pool)
        if (entry.score >= best - scoreBand) entry,
    ];

    final chosen = band[_random.nextInt(band.length)];
    _remember(ratingKeyOf(chosen.item));
    return RatingPick(item: chosen.item, score: chosen.score);
  }

  void _remember(String key) {
    _recent.remove(key);
    _recent.insert(0, key);
    if (_recent.length > recentLimit) {
      _recent.removeRange(recentLimit, _recent.length);
    }
  }
}
