import '../config/models/history_record.dart';

/// 历史候选的匹配层级（数值越小越精确）。
enum HistoryMatchLevel {
  /// 同一 `vodId` + 集名（当前站点精确记录）。
  exact,

  /// 规范化标题 + 规范化集名完全相等。
  exactName,

  /// 规范化标题相等，且双方集号相同。
  episodeNumber,

  /// 规范化标题相等，且双方都是电影标记（正片 / HD / 高清 / 完整版 / 电影）。
  movie,
}

class HistoryResumeMatch {
  final HistoryRecord record;
  final HistoryMatchLevel level;

  const HistoryResumeMatch({required this.record, required this.level});
}

class _EpisodeIdentity {
  final String normalized;
  final int? number;
  final bool movie;

  const _EpisodeIdentity(this.normalized, this.number, this.movie);
}

const _movieMarkers = {'正片', 'hd', '高清', '完整版', '电影'};

/// 集名是否属于「电影标记」（正片 / HD / 高清 / 完整版 / 电影）。
bool isMovieEpisodeName(String value) =>
    _movieMarkers.contains(_normalize(value));

/// 规范化标题：去首尾空白、折叠空白、全角 ASCII 转半角、ASCII 小写。
///
/// 不做标点删除 / 繁简转换 / 模糊匹配。
String normalizeHistoryTitle(String value) => _normalize(value);

_EpisodeIdentity _episodeIdentity(String value) {
  final normalized = _normalize(value);
  final number = _extractEpisodeNumber(normalized);
  return _EpisodeIdentity(
    normalized,
    number,
    _movieMarkers.contains(normalized),
  );
}

int? _extractEpisodeNumber(String value) {
  final patterns = [
    RegExp(r'^第\s*0*(\d+)\s*[集话話期]$'),
    RegExp(r'^0*(\d+)$'),
    RegExp(r'^(?:ep|e)\s*0*(\d+)$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(value);
    if (match != null) return int.tryParse(match.group(1) ?? '');
  }
  return null;
}

String _normalize(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x3000) {
      buffer.write(' ');
      continue;
    }
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
      continue;
    }
    buffer.writeCharCode(rune);
  }
  return buffer
      .toString()
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
}

HistoryMatchLevel? _matchLevel(
  HistoryRecord record, {
  required String currentId,
  required String normalizedTitle,
  required _EpisodeIdentity currentEpisode,
  required bool singleEpisode,
}) {
  final sameTitle = normalizeHistoryTitle(record.vodName) == normalizedTitle;
  // 不同站点可能复用同一 vodId：exact 必须同时校验片名，避免 id 碰撞导致错片续播。
  if (record.id == currentId && sameTitle) {
    return HistoryMatchLevel.exact;
  }
  if (!sameTitle) return null;

  final otherEpisode = _episodeIdentity(record.episodeName);
  if (otherEpisode.normalized == currentEpisode.normalized) {
    return HistoryMatchLevel.exactName;
  }
  if (otherEpisode.number != null &&
      currentEpisode.number != null &&
      otherEpisode.number == currentEpisode.number) {
    return HistoryMatchLevel.episodeNumber;
  }
  if (otherEpisode.movie && currentEpisode.movie) {
    return HistoryMatchLevel.movie;
  }
  // 单集影片（电影 / 单本剧）：不同站点的集名差异很大（正片 / HD / 中字…），
  // 只要最外层片名一致就允许续播，避免因集名对不上而从头播放。
  if (singleEpisode) {
    return HistoryMatchLevel.movie;
  }
  return null;
}

/// 查找「同一影片 + 同一集」的最近一条可续播记录（SET-11）。
///
/// 规则：
/// - 同时检查 L0（精确 ID）与 L1–L3（同片同集）；
/// - 先过滤 `positionMs <= 0`，再按 `timestamp` 最新排序；
/// - 时间相同优先更精确层级，再取进度更大者；
/// - [singleEpisode] 为 true（单集影片）时，集名不再作为硬条件，只按片名匹配；
/// - 返回排序第一的候选（即使已播完），由调用方通过 `resumePosition` 决定是否续播。
HistoryResumeMatch? findLatestHistoryResumeMatch({
  required List<HistoryRecord> records,
  required String vodId,
  required String vodName,
  required String episodeName,
  bool singleEpisode = false,
}) {
  final normalizedTitle = normalizeHistoryTitle(vodName);
  if (normalizedTitle.isEmpty) return null;
  final currentEpisode = _episodeIdentity(episodeName);
  final currentId = HistoryRecord.buildId(vodId, episodeName);

  final candidates = <HistoryResumeMatch>[];
  for (final record in records) {
    if (record.positionMs <= 0) continue;
    final level = _matchLevel(
      record,
      currentId: currentId,
      normalizedTitle: normalizedTitle,
      currentEpisode: currentEpisode,
      singleEpisode: singleEpisode,
    );
    if (level == null) continue;
    candidates.add(HistoryResumeMatch(record: record, level: level));
  }
  if (candidates.isEmpty) return null;

  candidates.sort((a, b) {
    final byTime = b.record.timestamp.compareTo(a.record.timestamp);
    if (byTime != 0) return byTime;
    final byLevel = a.level.index.compareTo(b.level.index);
    if (byLevel != 0) return byLevel;
    return b.record.positionMs.compareTo(a.record.positionMs);
  });
  return candidates.first;
}
