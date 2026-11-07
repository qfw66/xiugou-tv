import '../api/models/vod_models.dart';
import '../api/netdisk_share_links.dart';
import '../config/models/history_record.dart';
import '../config/models/vod_config.dart';
import '../history/history_match.dart';
import 'line_switch_planner.dart';

/// 跨站故障转移的站源数量上限（方案 §3.4）。
const int maxCrossSiteSiteCount = 8;

/// 候选影片展示 / 手动尝试上限（方案 §3.4）。
const int maxCrossSiteCandidateCount = 3;

/// 特别篇类别。只有同类才允许配对：宁可少配，也不把剧场版和 OVA 混为一部。
enum CrossSiteSpecialKind {
  special('特别篇'),
  extra('番外'),
  ova('OVA'),
  oad('OAD'),
  theatrical('剧场版'),
  movieEdition('电影版'),
  sp('SP');

  const CrossSiteSpecialKind(this.label);

  final String label;
}

/// 方案 §3.5 的粗类型。
enum CrossSiteCoarseType {
  movie('电影'),
  series('剧集'),
  anime('动漫'),
  variety('综艺'),
  documentary('纪录'),
  shortDrama('短剧');

  const CrossSiteCoarseType(this.label);

  final String label;
}

/// 同名置信度。自动模式只有「唯一高置信」才允许不弹框直接切。
enum CrossSiteConfidence { high, medium, low }

/// 跨站集匹配结果。复用 [LineMatchKind] 的判定，再补一个单集影片特例。
enum CrossSiteEpisodeMatchKind { sameName, normalizedName, movieSingle }

/// 规范化后的片名身份：基础片名 + 季号 + 特别篇类别。
class CrossSiteTitleIdentity {
  const CrossSiteTitleIdentity({
    required this.raw,
    required this.base,
    this.season,
    this.special,
  });

  /// 原始片名（保留给提示 / 调试用）。
  final String raw;

  /// 去掉季号、特别篇标记、标点与空白并小写后的基础片名。
  final String base;

  /// 季号；未标注为 null。
  final int? season;

  /// 特别篇类别；普通正片为 null。
  final CrossSiteSpecialKind? special;

  bool get isValid => base.isNotEmpty;

  /// 方案 §3.5 的片名硬条件：基础片名、季号、特别篇类别都必须一致。
  ///
  /// 季号 / 特别篇「一边有一边没有」也视为不一致。
  bool matches(CrossSiteTitleIdentity other) {
    if (!isValid || !other.isValid) return false;
    return base == other.base &&
        season == other.season &&
        special == other.special;
  }

  @override
  bool operator ==(Object other) =>
      other is CrossSiteTitleIdentity &&
      other.base == base &&
      other.season == season &&
      other.special == special;

  @override
  int get hashCode => Object.hash(base, season, special);

  @override
  String toString() =>
      'CrossSiteTitleIdentity(base: $base, season: $season, special: $special)';
}

/// 当前正在播放的影片，作为跨站匹配的目标。
class CrossSiteTarget {
  const CrossSiteTarget({
    required this.item,
    required this.episodeName,
    required this.episodeCount,
    this.siteKey,
  });

  final VodItem item;
  final String episodeName;

  /// 当前线路的集数；0 表示未知。用于单集 / 多集判断。
  final int episodeCount;

  /// 当前站 key；[evaluateCrossSiteCandidate] 未显式传 currentSiteKey 时用它。
  final String? siteKey;

  CrossSiteTitleIdentity get identity => parseCrossSiteTitle(item.name);

  int? get year => parseCrossSiteYear(item.year);

  CrossSiteCoarseType? get coarseType =>
      inferCrossSiteCoarseType(item.typeName);
}

/// 某个候选线路上的集匹配结果。
class CrossSiteEpisodeMatch {
  const CrossSiteEpisodeMatch({
    required this.episodeIndex,
    required this.episode,
    required this.kind,
    required this.unique,
    required this.annotation,
  });

  final int episodeIndex;
  final VodEpisode episode;
  final CrossSiteEpisodeMatchKind kind;

  /// 是否唯一匹配。当前实现只会返回唯一匹配，保留字段给 P1 扩展。
  final bool unique;

  /// 给 UI / 日志的补充说明，例如「集名归一化匹配」。
  final String annotation;
}

/// 方案 §3.5 的匹配评分与置信度。
class CrossSiteMatchEvidence {
  const CrossSiteMatchEvidence({
    required this.score,
    required this.confidence,
    required this.yearMatched,
    required this.actorOverlap,
    required this.directorMatched,
    required this.typeMatched,
    required this.episodeCountClose,
    required this.remarksConsistent,
    required this.contentOverlap,
    required this.historyMatched,
  });

  final int score;
  final CrossSiteConfidence confidence;
  final bool yearMatched;
  final int actorOverlap;
  final bool directorMatched;
  final bool typeMatched;
  final bool episodeCountClose;
  final bool remarksConsistent;
  final bool contentOverlap;
  final bool historyMatched;

  /// 高置信必须至少有一个强证据：年份、演员或简介。
  bool get hasStrongEvidence =>
      yearMatched || actorOverlap > 0 || contentOverlap;
}

/// 一个通过硬条件的跨站候选。一个候选对应「一个站 + 一条线路」。
class CrossSiteCandidate {
  const CrossSiteCandidate({
    required this.site,
    required this.detail,
    required this.item,
    required this.configIndex,
    required this.sourceIndex,
    required this.source,
    required this.episodeMatch,
    required this.identity,
    required this.evidence,
    required this.netdisk,
  });

  final Site site;
  final VodDetail detail;
  final VodItem item;

  /// 站源在配置中的顺序，用于同分稳定排序。
  final int configIndex;
  final int sourceIndex;
  final PlayFrom source;
  final CrossSiteEpisodeMatch episodeMatch;
  final CrossSiteTitleIdentity identity;
  final CrossSiteMatchEvidence evidence;

  /// 详情里是否含网盘分享链接；同一置信度下优先非网盘。
  final bool netdisk;

  int get score => evidence.score;

  CrossSiteConfidence get confidence => evidence.confidence;

  String get episodeName => episodeMatch.episode.name;

  bool get isSameName =>
      episodeMatch.kind == CrossSiteEpisodeMatchKind.sameName;
}

/// 把标题转成「基础片名 + 季号 + 特别篇」。
///
/// 季号 / 特别篇在去标点前抽取，所以 `《庆余年》第二季` 与 `庆余年 第2季`
/// 会得到同一个基础片名 `庆余年` 和同一个季号 2。
CrossSiteTitleIdentity parseCrossSiteTitle(String value) {
  final halfWidth = _toHalfWidth(value);
  final (season, withoutSeason) = _extractSeason(halfWidth);
  final (special, withoutSpecial) = _extractSpecial(withoutSeason);
  return CrossSiteTitleIdentity(
    raw: value,
    base: _normalizeTitleBase(withoutSpecial),
    season: season,
    special: special,
  );
}

/// 只保留基础片名：去标点、去空白、小写，并剔除季号 / 特别篇标记。
String normalizeCrossSiteTitle(String value) => parseCrossSiteTitle(value).base;

/// 候选片名是否带「预告 / 花絮 / 解说」等内容标记。
///
/// 这类视频经常与正片同名，但内容完全不同，方案要求直接拒绝。
bool containsCrossSiteContentMarker(String value) {
  if (value.isEmpty) return false;
  return _contentMarkerPattern.hasMatch(_toHalfWidth(value).toLowerCase());
}

/// 解析合法 4 位年份；`0`、空值、非 4 位数字和明显越界值都返回 null。
int? parseCrossSiteYear(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final match = _yearPattern.firstMatch(_toHalfWidth(value));
  if (match == null) return null;
  final year = int.tryParse(match.group(0)!);
  if (year == null || year <= 0) return null;
  return year;
}

/// 把站点 typeName 映射到方案 §3.5 的粗类型。
///
/// 映射不出来（例如「动作」「剧情」）返回 null；null 不参与互斥判断，
/// 避免因为分类缺失而误拒。
CrossSiteCoarseType? inferCrossSiteCoarseType(String? typeName) {
  if (typeName == null) return null;
  final normalized = _toHalfWidth(typeName).toLowerCase();
  if (normalized.trim().isEmpty) return null;
  final tokens = normalized
      .split(RegExp(r'[,，、/|｜;；\s]+'))
      .where((token) => token.isNotEmpty);
  for (final token in tokens) {
    final type = _coarseTypeOfToken(token);
    if (type != null) return type;
  }
  return null;
}

/// 方案 §4：先复用 [matchEpisodeOnLine]；只有候选与当前都是单集影片时，
/// 才允许「单集对单集」的 [CrossSiteEpisodeMatchKind.movieSingle] 特例。
///
/// 多条同名 / 无匹配 / 集号越界 / 单集候选对多集当前集，全部返回 null，
/// 不按索引猜。
CrossSiteEpisodeMatch? matchCrossSiteEpisode({
  required PlayFrom source,
  required String targetEpisodeName,
  required int targetEpisodeCount,
}) {
  if (source.episodes.isEmpty) return null;
  final targetName = targetEpisodeName.trim();
  if (targetName.isEmpty) return null;

  // 候选只有一集、当前却是多集：候选无法覆盖整部剧，直接拒绝。
  if (source.episodes.length == 1 && targetEpisodeCount > 1) return null;

  final ordinal = _targetEpisodeOrdinal(targetName);
  if (ordinal != null && ordinal > source.episodes.length) return null;

  final direct = matchEpisodeOnLine(source, targetName);
  if (direct != null) {
    final kind = direct.matchedBy == LineMatchKind.sameName
        ? CrossSiteEpisodeMatchKind.sameName
        : CrossSiteEpisodeMatchKind.normalizedName;
    return CrossSiteEpisodeMatch(
      episodeIndex: direct.episodeIndex,
      episode: source.episodes[direct.episodeIndex],
      kind: kind,
      unique: true,
      annotation:
          kind == CrossSiteEpisodeMatchKind.normalizedName ? '集名归一化匹配' : '',
    );
  }

  // 单集影片特例：双方都只有一集，且集名都是电影标记（正片 / HD / 高清…）。
  // 当前集数未知（0）不能当作「单集」，否则可能把单集影片错配给多集剧。
  if (source.episodes.length != 1 || targetEpisodeCount != 1) return null;
  final candidateEpisode = source.episodes.single;
  if (!isMovieEpisodeName(targetName) ||
      !isMovieEpisodeName(candidateEpisode.name)) {
    return null;
  }
  return CrossSiteEpisodeMatch(
    episodeIndex: 0,
    episode: candidateEpisode,
    kind: CrossSiteEpisodeMatchKind.movieSingle,
    unique: true,
    annotation: '单集影片（按唯一一集匹配）',
  );
}

/// 方案 §3.5 的评分与置信度。只计分，不做同名 / 年份 / 类型的硬拒绝；
/// 硬条件由 [evaluateCrossSiteCandidate] 负责。
CrossSiteMatchEvidence scoreCrossSiteMatch({
  required VodItem target,
  required VodItem candidate,
  required String targetEpisodeName,
  required int targetEpisodeCount,
  required int candidateEpisodeCount,
  String? candidateSiteKey,
  Iterable<HistoryRecord> history = const <HistoryRecord>[],
}) {
  final targetYear = parseCrossSiteYear(target.year);
  final candidateYear = parseCrossSiteYear(candidate.year);
  final yearMatched = targetYear != null &&
      candidateYear != null &&
      targetYear != 0 &&
      candidateYear != 0 &&
      targetYear == candidateYear;

  final actorOverlap = _actorOverlap(target.actor, candidate.actor);
  final directorMatched =
      _sameComparableText(target.director, candidate.director);

  final targetType = inferCrossSiteCoarseType(target.typeName);
  final candidateType = inferCrossSiteCoarseType(candidate.typeName);
  final typeMatched = targetType != null &&
      candidateType != null &&
      targetType == candidateType;

  // 单集 / 单集（电影）的集数相同不构成「集数吻合」证据，否则所有电影都会
  // 白拿 1 分，年份一项就能冲到高置信。
  final episodeCountClose = targetEpisodeCount > 1 &&
      candidateEpisodeCount > 1 &&
      (targetEpisodeCount - candidateEpisodeCount).abs() <= 1;

  final remarksConsistent =
      _remarksMatchEpisodeCount(candidate.remarks, candidateEpisodeCount);
  final contentOverlap = _contentOverlap(target.content, candidate.content);
  final historyMatched = _historyHasSameFilmAndEpisode(
    history: history,
    siteKey: candidateSiteKey,
    target: target,
    targetEpisodeName: targetEpisodeName,
  );

  var score = 0;
  if (yearMatched) score += 3;
  if (actorOverlap >= 2) {
    score += 2;
  } else if (actorOverlap == 1) {
    score += 1;
  }
  if (directorMatched) score += 1;
  if (typeMatched) score += 1;
  if (episodeCountClose) score += 1;
  if (remarksConsistent) score += 1;
  if (contentOverlap) score += 1;
  if (historyMatched) score += 1;

  final hasStrongEvidence = yearMatched || actorOverlap > 0 || contentOverlap;
  final confidence = score >= 4 && hasStrongEvidence
      ? CrossSiteConfidence.high
      : score >= 2
          ? CrossSiteConfidence.medium
          : CrossSiteConfidence.low;

  return CrossSiteMatchEvidence(
    score: score,
    confidence: confidence,
    yearMatched: yearMatched,
    actorOverlap: actorOverlap,
    directorMatched: directorMatched,
    typeMatched: typeMatched,
    episodeCountClose: episodeCountClose,
    remarksConsistent: remarksConsistent,
    contentOverlap: contentOverlap,
    historyMatched: historyMatched,
  );
}

/// 校验一部候选影片的硬条件并给出匹配证据。
///
/// [sourceIndex] 指定候选详情里的线路；P1 一般用
/// [planCrossSiteCandidate] 自动挑线路。
CrossSiteCandidate? evaluateCrossSiteCandidate({
  required CrossSiteTarget target,
  required Site site,
  required VodDetail detail,
  int configIndex = 0,
  int sourceIndex = 0,
  Set<String> visitedSiteKeys = const <String>{},
  String? currentSiteKey,
  Iterable<HistoryRecord> history = const <HistoryRecord>[],
}) {
  final currentKey = currentSiteKey ?? target.siteKey;
  if (site.key == currentKey) return null;
  if (visitedSiteKeys.contains(site.key)) return null;
  if (site.searchable == 0 || site.api.trim().isEmpty || site.isPythonSource) {
    return null;
  }

  final candidateItem = detail.item;
  final candidateName = candidateItem.name.trim();
  if (candidateName.isEmpty) return null;
  if (containsCrossSiteContentMarker(candidateName)) return null;

  final candidateIdentity = parseCrossSiteTitle(candidateName);
  if (!candidateIdentity.matches(target.identity)) return null;

  final targetYear = target.year;
  final candidateYear = parseCrossSiteYear(candidateItem.year);
  if (targetYear != null &&
      targetYear != 0 &&
      candidateYear != null &&
      candidateYear != 0 &&
      targetYear != candidateYear) {
    return null;
  }

  final targetType = target.coarseType;
  final candidateType = inferCrossSiteCoarseType(candidateItem.typeName);
  if (targetType != null &&
      candidateType != null &&
      targetType != candidateType) {
    return null;
  }

  if (sourceIndex < 0 || sourceIndex >= detail.sources.length) return null;
  final source = detail.sources[sourceIndex];
  final episodeMatch = matchCrossSiteEpisode(
    source: source,
    targetEpisodeName: target.episodeName,
    targetEpisodeCount: target.episodeCount,
  );
  if (episodeMatch == null) return null;

  final evidence = scoreCrossSiteMatch(
    target: target.item,
    candidate: candidateItem,
    targetEpisodeName: target.episodeName,
    targetEpisodeCount: target.episodeCount,
    candidateEpisodeCount: source.episodes.length,
    candidateSiteKey: site.key,
    history: history,
  );

  return CrossSiteCandidate(
    site: site,
    detail: detail,
    item: candidateItem,
    configIndex: configIndex,
    sourceIndex: sourceIndex,
    source: source,
    episodeMatch: episodeMatch,
    identity: candidateIdentity,
    evidence: evidence,
    netdisk: extractNetdiskShareLinks(detail).isNotEmpty,
  );
}

/// 在一部候选详情里挑选最佳线路：同名集优先于归一化集，再按线路顺序。
///
/// 方案 §3.3：每个候选影片优先选同名集线路，其次按线路顺序选第一个可匹配线路。
CrossSiteCandidate? planCrossSiteCandidate({
  required CrossSiteTarget target,
  required Site site,
  required VodDetail detail,
  int configIndex = 0,
  Set<String> visitedSiteKeys = const <String>{},
  String? currentSiteKey,
  Iterable<HistoryRecord> history = const <HistoryRecord>[],
}) {
  CrossSiteCandidate? best;
  for (var sourceIndex = 0;
      sourceIndex < detail.sources.length;
      sourceIndex++) {
    final candidate = evaluateCrossSiteCandidate(
      target: target,
      site: site,
      detail: detail,
      configIndex: configIndex,
      sourceIndex: sourceIndex,
      visitedSiteKeys: visitedSiteKeys,
      currentSiteKey: currentSiteKey,
      history: history,
    );
    if (candidate == null) continue;
    if (best == null ||
        _episodeKindRank(candidate.episodeMatch.kind) <
            _episodeKindRank(best.episodeMatch.kind)) {
      best = candidate;
    }
  }
  return best;
}

/// 候选排序与截断（方案 §3.4 / §8）：分数降序，其次历史、非网盘、
/// sameName > normalizedName > movieSingle、配置顺序，最后保持输入顺序。
List<CrossSiteCandidate> rankCrossSiteCandidates(
  Iterable<CrossSiteCandidate> candidates, {
  int limit = maxCrossSiteCandidateCount,
}) {
  final effectiveLimit = limit <= 0
      ? 0
      : (limit > maxCrossSiteCandidateCount
          ? maxCrossSiteCandidateCount
          : limit);
  if (effectiveLimit == 0) return const <CrossSiteCandidate>[];

  final list = candidates.toList(growable: false);
  final indexed = <(int, CrossSiteCandidate)>[
    for (var index = 0; index < list.length; index++) (index, list[index]),
  ];
  indexed.sort((left, right) {
    final compared = _compareCrossSiteCandidates(left.$2, right.$2);
    if (compared != 0) return compared;
    return left.$1.compareTo(right.$1);
  });
  return indexed
      .take(effectiveLimit)
      .map((entry) => entry.$2)
      .toList(growable: false);
}

/// 方案 §3.2 / §3.4：从配置站源里构造跨站尝试列表。
///
/// 排除：当前站、[visitedSiteKeys]、关闭搜索 / api 为空的站、Python 源、
/// 与已选站同 host 的站；[automatic] 为 true 时再排除未启动 Companion 的源。
/// 保持配置顺序，最多 [maxCrossSiteSiteCount] 个。
///
/// P0 不引入 settings 策略枚举，自动 / 手动的差异由 [automatic] 显式表达。
List<Site> buildCrossSiteSiteList({
  required List<Site> sites,
  String? currentSiteKey,
  Set<String> visitedSiteKeys = const <String>{},
  bool automatic = false,
  bool companionRunning = false,
  int limit = maxCrossSiteSiteCount,
}) {
  final effectiveLimit = limit <= 0
      ? 0
      : (limit > maxCrossSiteSiteCount ? maxCrossSiteSiteCount : limit);
  if (effectiveLimit == 0) return const <Site>[];

  // 同一个 CMS 可能配了多个 key：当前站已用的 host 也不能再选。
  final hosts = <String>{};
  if (currentSiteKey != null) {
    for (final site in sites) {
      if (site.key != currentSiteKey) continue;
      final host = _siteHost(site);
      if (host != null) hosts.add(host);
    }
  }

  final result = <Site>[];
  for (final site in sites) {
    if (result.length >= effectiveLimit) break;
    if (site.key == currentSiteKey) continue;
    if (visitedSiteKeys.contains(site.key)) continue;
    if (site.searchable == 0) continue;
    if (site.api.trim().isEmpty) continue;
    if (site.isPythonSource) continue;
    if (automatic && site.usesCompanion && !companionRunning) continue;
    final host = _siteHost(site);
    if (host != null && !hosts.add(host)) continue;
    result.add(site);
  }
  return List<Site>.unmodifiable(result);
}

// ---------------------------------------------------------------------------
// 标题规范化
// ---------------------------------------------------------------------------

const Map<String, int> _chineseDigits = <String, int>{
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};

final List<RegExp> _seasonPatterns = <RegExp>[
  RegExp(r'第\s*(\d{1,3})\s*季'),
  RegExp(r'第\s*([零〇一二两三四五六七八九十]{1,4})\s*季'),
  RegExp(r'season\s*(\d{1,3})', caseSensitive: false),
  RegExp(r'\bs\s*(\d{1,3})\b', caseSensitive: false),
];

final List<(CrossSiteSpecialKind, RegExp)> _specialPatterns =
    <(CrossSiteSpecialKind, RegExp)>[
  (CrossSiteSpecialKind.special, RegExp('特别篇')),
  (CrossSiteSpecialKind.extra, RegExp('番外篇?')),
  (CrossSiteSpecialKind.ova, RegExp(r'\bova\b', caseSensitive: false)),
  (CrossSiteSpecialKind.oad, RegExp(r'\boad\b', caseSensitive: false)),
  (CrossSiteSpecialKind.theatrical, RegExp('剧场版')),
  (CrossSiteSpecialKind.movieEdition, RegExp('电影版')),
  (CrossSiteSpecialKind.sp, RegExp(r'\bsp\b', caseSensitive: false)),
];

final RegExp _contentMarkerPattern = RegExp('预告|花絮|解说|片段|混剪|速看|盘点|幕后|特辑');

final RegExp _yearPattern = RegExp(r'(?<!\d)(?:19|20)\d{2}(?!\d)');

final RegExp _punctuationPattern = RegExp(
  r'[\s!-/:-@\[-`{-~、。，．；：？！…—–～·「」『』【】〔〕（）《》〈〉“”‘’＂＇｀｜／＼＃＆＊＋－＝＜＞＠・]',
);

final RegExp _remarksEpisodePattern =
    RegExp(r'(?:全|更新至|更新到|共)\s*第?\s*0*(\d{1,4})\s*集');

String _toHalfWidth(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x3000) {
      buffer.write(' ');
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

(int?, String) _extractSeason(String text) {
  var working = text;
  int? season;
  for (final pattern in _seasonPatterns) {
    final matches = pattern.allMatches(working).toList(growable: false);
    if (matches.isEmpty) continue;
    if (season == null) {
      final raw = matches.first.group(1);
      if (raw != null) season = _parseSeasonNumber(raw);
    }
    for (final match in matches.reversed) {
      working = working.replaceRange(match.start, match.end, ' ');
    }
  }
  return (season, working);
}

int? _parseSeasonNumber(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final digits = int.tryParse(value);
  if (digits != null) return digits;
  return _parseChineseNumeral(value);
}

int? _parseChineseNumeral(String value) {
  if (value == '十') return 10;
  final tenIndex = value.indexOf('十');
  if (tenIndex >= 0) {
    final left = value.substring(0, tenIndex);
    final right = value.substring(tenIndex + 1);
    final tens = left.isEmpty ? 1 : _chineseDigits[left];
    final ones = right.isEmpty ? 0 : _chineseDigits[right];
    if (tens == null || ones == null) return null;
    return tens * 10 + ones;
  }
  var result = 0;
  for (final char in value.split('')) {
    final digit = _chineseDigits[char];
    if (digit == null) return null;
    result = result * 10 + digit;
  }
  return result;
}

(CrossSiteSpecialKind?, String) _extractSpecial(String text) {
  var working = text;
  CrossSiteSpecialKind? special;
  for (final entry in _specialPatterns) {
    final matches = entry.$2.allMatches(working).toList(growable: false);
    if (matches.isEmpty) continue;
    special ??= entry.$1;
    for (final match in matches.reversed) {
      working = working.replaceRange(match.start, match.end, ' ');
    }
  }
  return (special, working);
}

String _normalizeTitleBase(String value) =>
    _stripPunctuation(value).replaceAll(RegExp(r'\s+'), '').toLowerCase();

String _stripPunctuation(String value) =>
    value.replaceAll(_punctuationPattern, '');

String _comparableText(String? value) {
  if (value == null || value.trim().isEmpty) return '';
  return _normalizeTitleBase(value);
}

CrossSiteCoarseType? _coarseTypeOfToken(String token) {
  final value = token.trim();
  if (value.isEmpty) return null;

  if (value.contains('短剧')) return CrossSiteCoarseType.shortDrama;
  if (value.contains('纪录') ||
      value.contains('纪实') ||
      value == 'doc' ||
      value == 'documentary') {
    return CrossSiteCoarseType.documentary;
  }
  if (value.contains('综艺') ||
      value.contains('真人秀') ||
      value.contains('脱口秀') ||
      value.contains('晚会') ||
      value == 'variety' ||
      value == 'show') {
    return CrossSiteCoarseType.variety;
  }

  // 「动画电影」按电影处理；「动画片」仍归动漫。
  if (value.contains('动画') && value.contains('电影')) {
    return CrossSiteCoarseType.movie;
  }
  if (value.contains('动漫') ||
      value.contains('动画') ||
      value.contains('番剧') ||
      value.contains('国漫') ||
      value.contains('日漫') ||
      value == 'anime' ||
      value == 'animation') {
    return CrossSiteCoarseType.anime;
  }

  if (value.contains('电视剧') ||
      value.contains('连续剧') ||
      value.contains('剧集') ||
      value == 'tv' ||
      value == 'series' ||
      value == 'tvseries' ||
      value.endsWith('剧')) {
    return CrossSiteCoarseType.series;
  }

  if (value.contains('电影') ||
      value == 'movie' ||
      value == 'film' ||
      value.endsWith('片')) {
    return CrossSiteCoarseType.movie;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 集匹配 / 评分辅助
// ---------------------------------------------------------------------------

int? _targetEpisodeOrdinal(String episodeName) {
  final halfWidth = _toHalfWidth(episodeName);
  final patterns = <RegExp>[
    RegExp(r'第\s*0*(\d{1,4})\s*[集话期回]'),
    RegExp(r'\b(?:ep|e)\s*0*(\d{1,4})\b', caseSensitive: false),
    RegExp(r'^\s*0*(\d{1,4})\s*$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(halfWidth);
    if (match == null) continue;
    final ordinal = int.tryParse(match.group(1)!);
    if (ordinal != null && ordinal > 0) return ordinal;
  }
  return null;
}

int _episodeKindRank(CrossSiteEpisodeMatchKind kind) {
  switch (kind) {
    case CrossSiteEpisodeMatchKind.sameName:
      return 0;
    case CrossSiteEpisodeMatchKind.normalizedName:
      return 1;
    case CrossSiteEpisodeMatchKind.movieSingle:
      return 2;
  }
}

List<String> _personNames(String? value) {
  if (value == null || value.trim().isEmpty) return const <String>[];
  final seen = <String>{};
  final result = <String>[];
  for (final part in _toHalfWidth(value).split(RegExp(r'[,，、/|｜;；\s]+'))) {
    final name = _stripPunctuation(part).toLowerCase();
    if (name.runes.length < 2) continue;
    if (seen.add(name)) result.add(name);
  }
  return result;
}

int _actorOverlap(String? target, String? candidate) {
  final targetNames = _personNames(target);
  if (targetNames.isEmpty) return 0;
  final candidateNames = _personNames(candidate).toSet();
  if (candidateNames.isEmpty) return 0;
  return targetNames.where(candidateNames.contains).length;
}

bool _sameComparableText(String? left, String? right) {
  final normalizedLeft = _comparableText(left);
  final normalizedRight = _comparableText(right);
  return normalizedLeft.isNotEmpty &&
      normalizedRight.isNotEmpty &&
      normalizedLeft == normalizedRight;
}

bool _remarksMatchEpisodeCount(String? remarks, int episodeCount) {
  if (remarks == null || episodeCount <= 0) return false;
  final match = _remarksEpisodePattern.firstMatch(_toHalfWidth(remarks));
  if (match == null) return false;
  return int.tryParse(match.group(1)!) == episodeCount;
}

bool _contentOverlap(String? target, String? candidate) {
  final left = _compactContent(target);
  final right = _compactContent(candidate);
  if (left.length < 12 || right.length < 12) return false;
  return _hasCommonSegment(left, right, 12);
}

String _compactContent(String? value) {
  if (value == null) return '';
  return _toHalfWidth(value).replaceAll(RegExp(r'\s+'), '');
}

bool _hasCommonSegment(String left, String right, int length) {
  if (left.length < length || right.length < length) return false;
  final segments = <String>{};
  for (var index = 0; index + length <= left.length; index++) {
    segments.add(left.substring(index, index + length));
  }
  for (var index = 0; index + length <= right.length; index++) {
    if (segments.contains(right.substring(index, index + length))) return true;
  }
  return false;
}

bool _historyHasSameFilmAndEpisode({
  required Iterable<HistoryRecord> history,
  required String? siteKey,
  required VodItem target,
  required String targetEpisodeName,
}) {
  if (siteKey == null || siteKey.isEmpty) return false;
  final targetIdentity = parseCrossSiteTitle(target.name);
  if (!targetIdentity.isValid) return false;
  final targetEpisode = targetEpisodeName.trim();
  final targetNormalized = normalizeEpisodeName(targetEpisode);

  for (final record in history) {
    if (record.siteKey != siteKey) continue;
    if (!parseCrossSiteTitle(record.vodName).matches(targetIdentity)) continue;
    final recordEpisode = record.episodeName.trim();
    if (recordEpisode == targetEpisode) return true;
    if (targetNormalized.isNotEmpty &&
        normalizeEpisodeName(recordEpisode) == targetNormalized) {
      return true;
    }
    if (isMovieEpisodeName(recordEpisode) &&
        isMovieEpisodeName(targetEpisode)) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// 候选排序 / 站源辅助
// ---------------------------------------------------------------------------

int _compareCrossSiteCandidates(
  CrossSiteCandidate left,
  CrossSiteCandidate right,
) {
  var compared = right.evidence.score.compareTo(left.evidence.score);
  if (compared != 0) return compared;

  final leftHistory = left.evidence.historyMatched ? 1 : 0;
  final rightHistory = right.evidence.historyMatched ? 1 : 0;
  compared = rightHistory.compareTo(leftHistory);
  if (compared != 0) return compared;

  final leftNetdisk = left.netdisk ? 1 : 0;
  final rightNetdisk = right.netdisk ? 1 : 0;
  compared = leftNetdisk.compareTo(rightNetdisk);
  if (compared != 0) return compared;

  compared = _episodeKindRank(left.episodeMatch.kind)
      .compareTo(_episodeKindRank(right.episodeMatch.kind));
  if (compared != 0) return compared;

  return left.configIndex.compareTo(right.configIndex);
}

String? _siteHost(Site site) {
  final api = site.api.trim();
  if (api.isEmpty) return null;
  final direct = Uri.tryParse(api);
  if (direct != null && direct.host.isNotEmpty) {
    return direct.host.toLowerCase();
  }
  final withScheme = Uri.tryParse('https://$api');
  if (withScheme != null && withScheme.host.isNotEmpty) {
    return withScheme.host.toLowerCase();
  }
  return null;
}
