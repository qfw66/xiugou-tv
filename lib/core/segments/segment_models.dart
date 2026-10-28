import 'dart:convert';

import 'package:crypto/crypto.dart';

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

/// 一集的跨站身份（§44）：`sha1(规范化片名|集序号)`。
///
/// 不含年份：不少站点不给年份，带上会让同一部片在不同站算出不同的键；
/// 同名不同片靠「本集时长 ±15 秒」区分（见 [SharedSegment.matchesDuration]）。
class SegmentEpisodeKey {
  const SegmentEpisodeKey._(this.key, this.title, this.episode);

  final String key;
  final String title;
  final int episode;

  /// 无法识别集序号（集名是乱码 / 纯文件 hash 等）时返回 null：不共享、不拉取。
  static SegmentEpisodeKey? of({
    required String title,
    required String episodeName,
    required int episodeCount,
  }) {
    final t = normalizeTitle(title);
    if (t.isEmpty) return null;
    final ep = episodeCount <= 1 ? 1 : parseEpisodeNumber(episodeName);
    if (ep == null) return null;
    final key = sha1.convert(utf8.encode('$t|$ep')).toString();
    return SegmentEpisodeKey._(key, title.trim(), ep);
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
    return half
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'[\(\[【（《<][^\)\]】）》>]*[\)\]】）》>]'), '')
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  }

  /// 从集名里解析集序号：第N集 / EPN / SxxEyy / 纯数字 / 网盘文件名开头的数字。
  static int? parseEpisodeNumber(String name) {
    final s = name.trim().toLowerCase();
    final patterns = [
      RegExp(r'第\s*0*(\d{1,4})\s*[集话話期回]'),
      RegExp(r's\d{1,2}\s*e0*(\d{1,4})'),
      // EP07 / E07：前后都不能紧挨字母数字，避免把 hash 里的「e1」当成集号
      RegExp(r'(?:^|[^a-z0-9])ep?\s*0*(\d{1,4})(?![a-z0-9])'),
      RegExp(r'^0*(\d{1,4})$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(s);
      if (m != null) return _positive(m.group(1));
    }
    // 网盘文件名：「[1.76 GB]01-4K.高码率.mkv」→ 去掉括号附注后取开头的数字
    final stripped = s.replaceAll(RegExp(r'[\(\[【（][^\)\]】）]*[\)\]】）]'), '').trim();
    final m = RegExp(r'^0*(\d{1,4})(?![\d.]*\s*(?:k|p|gb|mb|fps|bit))').firstMatch(stripped);
    return m == null ? null : _positive(m.group(1));
  }

  static int? _positive(String? s) {
    final n = int.tryParse(s ?? '');
    return n == null || n <= 0 ? null : n;
  }
}

/// 加载状态。
enum SegmentsPhase { idle, loading, ready, failed, unavailable }

class SegmentsState {
  const SegmentsState({
    this.phase = SegmentsPhase.idle,
    this.episode,
    this.segments = const [],
    this.submitted = const {},
    this.message,
  });

  final SegmentsPhase phase;

  /// 当前集身份；[SegmentsPhase.unavailable] 时为 null（识别不出集序号）。
  final SegmentEpisodeKey? episode;
  final List<SharedSegment> segments;

  /// 本客户端在这一集已经提交过的分类（每人每集每种分类只能提交一次）。
  final Set<SegmentCategory> submitted;
  final String? message;

  SegmentsState copyWith({
    SegmentsPhase? phase,
    List<SharedSegment>? segments,
    Set<SegmentCategory>? submitted,
    String? message,
  }) =>
      SegmentsState(
        phase: phase ?? this.phase,
        episode: episode,
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
