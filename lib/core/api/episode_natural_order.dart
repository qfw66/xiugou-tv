import 'package:flutter/foundation.dart' show debugPrint;

import '../danmaku/danmaku_matcher.dart' show EpisodeNumber;

/// 选集「自然集序」整理。
///
/// 网盘与部分站源按文件名 / 体积 / 时间列出文件，同一线路里的集号是乱的
/// （如「[1.2GB]E11.mkv」排在「[1.1GB]E01.mkv」前面，「10.mp4」排在「2.mp4」前面）。
/// 这里只在确实乱序、且能安全判定时才按集号重排（保守口径）：
/// - 至少 3 集：2 集且集号不同时必然是升序或降序，无从判断「乱」；
/// - 每个集名都能解析出正集号（[EpisodeNumber.parse]，体积 / 分辨率 / 年份 / 编码先剔除）；
///   有一集解析不出（预告 / 花絮 / 「正片」）整条线路不动；
/// - 集号互不重复，带季号的集季号一致：多季重号、季混排不动；
/// - 原顺序既不是升序也不是严格降序：刻意倒序（综艺最新一期在前）保持原样。
///
/// 返回重排后的原下标序列（第 k 项 = 新列表第 k 集在原列表里的下标）；不需要或不能重排时返回 null。
/// 集号互不重复，排序结果唯一，不依赖排序算法的稳定性。
List<int>? naturalEpisodeOrder(List<String> names, {String? title}) {
  if (names.length < 3) return null;
  final numbers = <int>[];
  final seen = <int>{};
  int? season;
  for (final name in names) {
    final parsed = EpisodeNumber.parse(name, title: title);
    final number = parsed.number;
    if (number == null || number <= 0 || !seen.add(number)) return null;
    final s = parsed.season;
    if (s != null) {
      if (season != null && season != s) return null;
      season = s;
    }
    numbers.add(number);
  }
  var ascending = true;
  var descending = true;
  for (var i = 1; i < numbers.length; i++) {
    if (numbers[i] < numbers[i - 1]) ascending = false;
    if (numbers[i] > numbers[i - 1]) descending = false;
  }
  if (ascending || descending) return null;
  return List<int>.generate(numbers.length, (i) => i)
    ..sort((a, b) => numbers[a].compareTo(numbers[b]));
}

/// 按 [naturalEpisodeOrder] 整理 [episodes]；不需要重排时原样返回同一个列表。
///
/// 只在解析出口调用一次（`VodDetail.fromJson` / `fromXml`），抽屉、详情页选集、
/// 上一集 / 下一集、自动连播都用整理后的同一份列表。
/// 实际重排时打一条 debug 日志（站点 key、片名、线路名、条数），方便实机核对。
List<T> naturalEpisodeList<T>(
  List<T> episodes, {
  required String Function(T episode) nameOf,
  String? title,
  String? siteKey,
  String? lineName,
}) {
  final order = naturalEpisodeOrder(
    [for (final episode in episodes) nameOf(episode)],
    title: title,
  );
  if (order == null) return episodes;
  debugPrint('--> [选集整理] site=${siteKey ?? '-'} vod=${title ?? '-'} '
      'line=${lineName ?? '-'} count=${episodes.length}：源顺序乱序，按集号重排');
  return [for (final i in order) episodes[i]];
}
