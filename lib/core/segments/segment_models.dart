import 'dart:convert';

import 'package:crypto/crypto.dart';

// 集号解析复用弹幕那套（中文数字 / SxxEyy / EP / 去片名与分辨率噪音），
// 之前片段自己实现的那份认不出「第十二集」「正片」「01话」等写法。
import '../danmaku/danmaku_matcher.dart' show EpisodeNumber;

/// 共享片段分类（§44）。键与服务端 `server/segments-worker/src/rules.js` 一致。
enum SegmentCategory {
  intro('intro', '片头'),
  outro('outro', '片尾'),
  recap('recap', '前情回顾'),
  preview('preview', '下集预告'),
  ad('ad', '广告'),
  other('other', '其他');

  const SegmentCategory(this.key, this.label);
  final String key;
  final String label;

  static SegmentCategory? of(String? key) {
    for (final c in values) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// 片段动作：播放到这一段时做什么。
enum SegmentAction {
  skip('skip', '跳过'),
  mute('mute', '静音'),
  highlight('highlight', '精彩时刻');

  const SegmentAction(this.key, this.label);
  final String key;
  final String label;

  static SegmentAction? of(String? key) {
    for (final a in values) {
      if (a.key == key) return a;
    }
    return null;
  }
}

/// 服务端采纳的一条共享片段（多数一致的结果）。
class SharedSegment {
  const SharedSegment({
    required this.category,
    required this.action,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
    required this.votes,
    this.total = 0,
  });

  final SegmentCategory category;
  final SegmentAction action;
  final int startMs;
  final int endMs;

  /// 提交者那一集的总时长：本地时长相差超过 [sameCutToleranceMs] 视为不同剪辑版本，不采用。
  final int durationMs;

  /// 认可票数：提交者 + 播放时自动执行后没有「撤销」的观众（§44 2026-10-27 改版）。
  final int votes;
  final int total;

  static const int sameCutToleranceMs = 15000;
  /// 有人认可过（≥ 2 票）：时间轴色块画实，否则画淡。执行上不再区分（首提即自动执行）。
  static const int trustedVotes = 2;

  bool get trusted => votes >= trustedVotes;

  /// 同一集内的稳定标识（防重复执行用）。
  String get id => '${category.key}:$startMs-$endMs';

  bool matchesDuration(int localDurationMs) =>
      localDurationMs > 0 && (localDurationMs - durationMs).abs() <= sameCutToleranceMs;

  static SharedSegment? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final c = SegmentCategory.of(raw['category'] as String?);
    final a = SegmentAction.of(raw['action'] as String?);
    int? i(String k) => raw[k] is int ? raw[k] as int : (raw[k] is num ? (raw[k] as num).toInt() : null);
    final s = i('startMs'), e = i('endMs'), d = i('durationMs'), v = i('votes');
    if (c == null || a == null || s == null || e == null || d == null || v == null || e <= s) return null;
    return SharedSegment(
        category: c, action: a, startMs: s, endMs: e, durationMs: d, votes: v, total: i('total') ?? v);
  }

  @override
  bool operator ==(Object other) =>
      other is SharedSegment &&
      other.category == category &&
      other.action == action &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.durationMs == durationMs &&
      other.votes == votes &&
      other.total == total;

  @override
  int get hashCode => Object.hash(category, action, startMs, endMs, durationMs, votes, total);
}

/// 片段身份集号的**唯一**推导（2026-11-03 选集序号方案 §3.1）。
///
/// - 单集（[episodeCount] <= 1）：固定 1，`inferred = false`；
/// - 多集：先解析集名，成功即用，`inferred = false`；
/// - 多集 + 解析失败 + 位置合法：用 `episodeIndex + 1`，`inferred = true`；
/// - 其余：`number = null`（不共享）。
///
/// [inferred] 只是身份的「置信度」标注（UI 用它写「集号按选集顺序推断」），
/// **不参与 key 计算**。抽屉里的「序号」是列表位置，不经过这个函数。
({int? number, bool inferred}) resolveSegmentEpisodeNumber({
  required String title,
  required String episodeName,
  required int episodeCount,
  int? episodeIndex,
}) {
  if (episodeCount <= 1) return (number: 1, inferred: false);
  final parsed =
      SegmentEpisodeKey.parseEpisodeNumber(episodeName, title: title);
  if (parsed != null) return (number: parsed, inferred: false);
  // 集名认不出（「正片」「彩蛋」「上」等）才退回选集列表里的位置：
  // 键会带一点「按位置」的假设，但共享片段本身还有「本集时长 ±15 秒」校验兜底。
  if (episodeIndex != null &&
      episodeIndex >= 0 &&
      episodeIndex < episodeCount) {
    return (number: episodeIndex + 1, inferred: true);
  }
  return (number: null, inferred: false);
}

/// 一集的跨站身份（§44）：`sha1(规范化片名|集序号)`。
///
/// 不含年份：不少站点不给年份，带上会让同一部片在不同站算出不同的键；
/// 同名不同片靠「本集时长 ±15 秒」区分（见 [SharedSegment.matchesDuration]）。
class SegmentEpisodeKey {
  const SegmentEpisodeKey._(this.key, this.title, this.episode,
      {this.inferred = false});

  final String key;
  final String title;
  final int episode;

  /// 集号是否由「选集位置」兜底推断（[resolveSegmentEpisodeNumber]）。
  ///
  /// 只影响 UI 标注，**不参与 [key] 计算**，也不写进缓存 / 请求。
  final bool inferred;

  /// 无法识别集序号（集名是乱码 / 纯文件 hash 等）时返回 null：不共享、不拉取。
  static SegmentEpisodeKey? of({
    required String title,
    required String episodeName,
    required int episodeCount,
    int? episodeIndex,
  }) {
    final t = normalizeTitle(title);
    if (t.isEmpty) return null;
    final resolved = resolveSegmentEpisodeNumber(
      title: title,
      episodeName: episodeName,
      episodeCount: episodeCount,
      episodeIndex: episodeIndex,
    );
    final ep = resolved.number;
    if (ep == null) return null;
    final key = sha1.convert(utf8.encode('$t|$ep')).toString();
    return SegmentEpisodeKey._(key, title.trim(), ep,
        inferred: resolved.inferred);
  }

  /// 片名规范化：全角转半角、小写、去掉各种括号里的附注（年份 / 4K / 国语…）、去空白与标点。
  static String normalizeTitle(String value) {
    final half = StringBuffer();
    for (final r in value.runes) {
      if (r == 0x3000) {
        half.write(' ');
      } else if (r >= 0xFF01 && r <= 0xFF5E) {
        half.writeCharCode(r - 0xFEE0);
      } else {
        half.writeCharCode(r);
      }
    }
    final lower = half.toString().toLowerCase();
    String skeleton(String s) => s.replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
    final stripped = skeleton(lower.replaceAll(RegExp(r'[\(\[【（《<][^\)\]】）》>]*[\)\]】）》>]'), ''));
    // invariant: a title wholly wrapped in brackets（「《庆余年》」）is the title itself, not an annotation;
    // only this otherwise-empty case falls back, so keys of every other title stay unchanged.
    return stripped.isNotEmpty ? stripped : skeleton(lower);
  }

  /// 从集名里解析集序号。
  ///
  /// 直接复用弹幕的 [EpisodeNumber.parse]：它覆盖「第X集（含中文数字）」「SxxEyy」
  /// 「EP/E + 数字」「纯数字」，并会先剔除重复片名、分辨率、体积、音轨等噪音。
  /// [title] 用来去掉集名里重复的片名（「流浪地球2.mp4」里的 2 不是集号）。
  static int? parseEpisodeNumber(String name, {String? title}) {
    final n = EpisodeNumber.parse(name, title: title).number;
    return n == null || n <= 0 ? null : n;
  }
}

/// 片段面板的**显示快照**：把「列表位置」与「身份集号」并列放好，不参与任何计算。
///
/// - [ordinal] 来自**正在播放线路**的 `episodeIndex + 1`（列表里第几项）；
/// - [episode] 等于 [SegmentEpisodeKey.episode]（这是哪一集）；
/// - 两者绝不互相换算：由 [EpisodeRef.fromKey] 从 key 复制，保证
///   `ref.episode == key.episode`、`ref.inferred == key.inferred`。
///
/// 只放内存（[SegmentsState.episodeRef]），不落盘、不进服务端 / 缓存格式。
class EpisodeRef {
  const EpisodeRef({
    required this.ordinal,
    required this.name,
    required this.episode,
    required this.inferred,
  });

  /// 1 基列表位置。
  final int ordinal;

  /// 原始集名，不裁剪、不改写。
  final String name;

  /// 身份集号；绝不是 [ordinal]。
  final int episode;

  /// [episode] 是否由 [ordinal] 兜底推断（多集 + 集名解析失败）。
  final bool inferred;

  factory EpisodeRef.fromKey(
    SegmentEpisodeKey key, {
    required int ordinal,
    required String name,
  }) {
    assert(ordinal > 0, 'ordinal 是 1 基的列表位置');
    return EpisodeRef(
      ordinal: ordinal,
      name: name,
      episode: key.episode,
      inferred: key.inferred,
    );
  }
}

/// 加载状态。
enum SegmentsPhase { idle, loading, ready, failed, unavailable }

class SegmentsState {
  const SegmentsState({
    this.phase = SegmentsPhase.idle,
    this.episode,
    this.episodeRef,
    this.segments = const [],
    this.submitted = const {},
    this.message,
  });

  final SegmentsPhase phase;

  /// 当前集身份；[SegmentsPhase.unavailable] 时为 null（识别不出集序号）。
  final SegmentEpisodeKey? episode;

  /// 当前集的显示快照（列表位置 + 原始集名）；只为片段面板显示，不持久化。
  ///
  /// 调用方没给 `episodeIndex`（或位置不合法）时为 null：此时面板只显示现有主行。
  final EpisodeRef? episodeRef;
  final List<SharedSegment> segments;

  /// 本客户端在这一集已经提交过的分类（每人每集每种分类只能提交一次）。
  final Set<SegmentCategory> submitted;
  final String? message;

  SegmentsState copyWith({
    SegmentsPhase? phase,
    List<SharedSegment>? segments,
    Set<SegmentCategory>? submitted,
    String? message,
    EpisodeRef? episodeRef,
    bool clearEpisodeRef = false,
  }) =>
      SegmentsState(
        phase: phase ?? this.phase,
        episode: episode,
        episodeRef:
            clearEpisodeRef ? null : (episodeRef ?? this.episodeRef),
        segments: segments ?? this.segments,
        submitted: submitted ?? this.submitted,
        message: message,
      );
}

/// 用户在抽屉里填的一条待提交片段。
class SegmentDraft {
  const SegmentDraft({
    required this.category,
    required this.action,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
  });

  final SegmentCategory category;
  final SegmentAction action;
  final int startMs;
  final int endMs;
  final int durationMs;
}

/// 提交结果（message 直接显示给用户）。
class SegmentSubmitResult {
  const SegmentSubmitResult(this.ok, this.message);
  final bool ok;
  final String message;
}
