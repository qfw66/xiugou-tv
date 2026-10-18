import '../api/models/vod_models.dart';

/// 候选与当前集的匹配依据（用于提示与自检日志，让「是不是猜的」可追溯）。
enum LineMatchKind {
  /// 集名 trim 后完全相等。
  sameName,

  /// 归一化后相等（全角/空白、「第」前缀、「集/话/期/回」后缀、数字前导 0 差异）。
  normalizedName,
}

/// 单条备用线路候选。
class LineCandidate {
  final PlayFrom source;
  final VodEpisode episode;
  final int sourceIndex;
  final int episodeIndex;
  final LineMatchKind matchedBy;

  /// 会话内唯一键：线路下标 + 线路名（避免同名线路互相覆盖）。
  String get key => '$sourceIndex\u0000${source.name}';

  const LineCandidate({
    required this.source,
    required this.episode,
    required this.sourceIndex,
    required this.episodeIndex,
    this.matchedBy = LineMatchKind.sameName,
  });
}

/// 会话内的线路键（与 [LineCandidate.key] 同一规则）。
String lineSwitchKey(int sourceIndex, String sourceName) =>
    '$sourceIndex\u0000$sourceName';

/// 集名归一化：只做**确定性**变换，不做语义猜测。
///
/// - 全角数字 / 字母 → 半角；全角空格 → 半角，再去掉所有空白；
/// - 去掉前缀「第」、后缀「集 / 话 / 期 / 回」；
/// - 纯数字去前导 0（`01` → `1`，`0` 仍是 `0`）；
/// - 转小写。
///
/// 例：`第01集` / `01` / `第1集` / ` 1 集 ` → `1`。
String normalizeEpisodeName(String value) {
  final buffer = StringBuffer();
  for (final rune in value.trim().runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  var text = buffer.toString().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (text.startsWith('第')) text = text.substring(1);
  text = text.replaceFirst(RegExp(r'(集|话|期|回)$'), '');
  if (RegExp(r'^\d+$').hasMatch(text)) {
    text = text.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  }
  return text;
}

/// 某条线路上与目标集名的匹配结果。
class LineEpisodeMatch {
  final int episodeIndex;
  final LineMatchKind matchedBy;

  const LineEpisodeMatch(this.episodeIndex, this.matchedBy);
}

/// 在**单条**线路上查找目标集：同名唯一 → 归一化唯一 → 否则 null（不猜）。
///
/// 手动换线与自动换线共用同一规则，避免两条入口给出不同结果。
LineEpisodeMatch? matchEpisodeOnLine(PlayFrom source, String episodeName) {
  final targetName = episodeName.trim();
  final targetNormalized = normalizeEpisodeName(episodeName);
  final exact = <int>[];
  final normalized = <int>[];
  for (var episodeIndex = 0;
      episodeIndex < source.episodes.length;
      episodeIndex++) {
    final name = source.episodes[episodeIndex].name.trim();
    if (name == targetName) {
      exact.add(episodeIndex);
    } else if (targetNormalized.isNotEmpty &&
        normalizeEpisodeName(name) == targetNormalized) {
      normalized.add(episodeIndex);
    }
  }
  if (exact.length == 1) {
    return LineEpisodeMatch(exact.single, LineMatchKind.sameName);
  }
  // 只有「归一化后唯一」才接受：多条一律视为歧义，跳过不猜。
  if (exact.isEmpty && normalized.length == 1) {
    return LineEpisodeMatch(normalized.single, LineMatchKind.normalizedName);
  }
  return null;
}

/// 规划同站同片同集的备用线路（SET-12）。
///
/// 匹配分级（都要求「该线路内唯一」，绝不按索引猜）：
/// 1. 集名 `trim()` 后完全相等；
/// 2. 归一化后相等（见 [normalizeEpisodeName]）。
///
/// 其余规则：
/// - 排除当前线路与 `tried` 中已尝试的线路；
/// - 跳过与当前集 URL 相同的候选（换了也没用）；
/// - 按详情页顺序最多返回 [maxCandidates] 条。
List<LineCandidate> planLineCandidates({
  required List<PlayFrom> sources,
  required int currentSourceIndex,
  required String episodeName,
  required String currentEpisodeUrl,
  required Set<String> tried,
  int maxCandidates = 2,
}) {
  final targetUrl = currentEpisodeUrl.trim();
  final candidates = <LineCandidate>[];

  for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
    if (sourceIndex == currentSourceIndex) continue;
    final source = sources[sourceIndex];
    if (tried.contains(lineSwitchKey(sourceIndex, source.name))) continue;

    final match = matchEpisodeOnLine(source, episodeName);
    if (match == null) continue;

    final episode = source.episodes[match.episodeIndex];
    if (episode.url.trim() == targetUrl) continue;

    candidates.add(LineCandidate(
      source: source,
      episode: episode,
      sourceIndex: sourceIndex,
      episodeIndex: match.episodeIndex,
      matchedBy: match.matchedBy,
    ));
    if (candidates.length >= maxCandidates) break;
  }
  return candidates;
}
