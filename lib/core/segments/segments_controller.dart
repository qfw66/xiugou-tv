import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'segment_models.dart';
import 'segment_rules.dart';
import 'segments_api.dart';

/// §44 共享片段加载 / 提交（全应用一份；换集由宿主驱动 [load]，退出 [clear]）。
///
/// - 同一集重复 [load] 只拉一次；新请求的结果到达前切走了，旧结果丢弃；
/// - 拉到的结果缓存在 `<数据目录>/segments/<key>.json`（6 小时内不重拉，失败时回退到缓存）；
/// - 任何失败只改状态，不影响播放。
class SegmentsController extends ValueNotifier<SegmentsState> {
  SegmentsController({required SegmentsApi api, required String dataDir})
      : _api = api,
        _dir = p.join(dataDir, 'segments'),
        super(const SegmentsState());

  final SegmentsApi _api;
  final String _dir;
  int _epoch = 0;
  bool _disposed = false;
  String? _clientId;

  static const Duration cacheTtl = Duration(hours: 6);

  /// 客户端 ID：首次使用时随机生成并保存在数据目录（不含任何个人信息）。
  Future<String> clientId() async {
    if (_clientId != null) return _clientId!;
    final file = File(p.join(_dir, 'client_id'));
    try {
      final saved = (await file.readAsString()).trim();
      if (RegExp(r'^[A-Za-z0-9-]{16,64}$').hasMatch(saved)) return _clientId = saved;
    } catch (_) {}
    final rnd = Random.secure();
    final id = 'xg-${List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(id);
    } catch (_) {}
    return _clientId = id;
  }

  File _cacheFile(String key) => File(p.join(_dir, '$key.json'));

  Future<void> load({required String title, required String episodeName, required int episodeCount}) async {
    final episode =
        SegmentEpisodeKey.of(title: title, episodeName: episodeName, episodeCount: episodeCount);
    if (episode == null) {
      _epoch++;
      _set(const SegmentsState(phase: SegmentsPhase.unavailable, message: '识别不出集数，无法共享片段'));
      return;
    }
    if (value.episode?.key == episode.key && value.phase != SegmentsPhase.failed) return;
    final epoch = ++_epoch;
    _set(SegmentsState(phase: SegmentsPhase.loading, episode: episode));

    // 先用缓存把时间轴画出来（不等网络），随后总是向服务端要最新结果覆盖：
    // 共享片段会被别人撤下 / 新提交，只信缓存会让已撤下的片段一直执行（2026-10-27 实机反馈）。
    final cached = await _readCache(episode.key, fresh: true);
    if (epoch != _epoch) return;
    if (cached != null) {
      _set(value.copyWith(phase: SegmentsPhase.ready, segments: cached.segments, submitted: cached.submitted));
    }
    try {
      final res = await _api.fetch(episode.key, clientId: await clientId());
      if (epoch != _epoch) return;
      _set(value.copyWith(phase: SegmentsPhase.ready, segments: res.segments, submitted: res.submitted));
      unawaited(_writeCache(episode.key, res));
    } on SegmentsException catch (e) {
      if (epoch != _epoch) return;
      final stale = await _readCache(episode.key, fresh: false);
      if (epoch != _epoch) return;
      _set(stale != null
          ? value.copyWith(phase: SegmentsPhase.ready, segments: stale.segments, submitted: stale.submitted)
          : value.copyWith(phase: SegmentsPhase.failed, message: e.message));
    }
  }

  /// 提交一条片段：本地先按规则校验（不合理直接提示、不发请求），再交服务端。
  Future<SegmentSubmitResult> submit(SegmentDraft draft) async {
    final episode = value.episode;
    if (episode == null) return const SegmentSubmitResult(false, '识别不出集数，无法共享片段');
    if (value.submitted.contains(draft.category)) {
      return SegmentSubmitResult(false, '这一集的「${draft.category.label}」你已经提交过了');
    }
    final violation = SegmentRules.validate(
        category: draft.category, startMs: draft.startMs, endMs: draft.endMs, durationMs: draft.durationMs);
    if (violation != null) return SegmentSubmitResult(false, violation.message);
    try {
      final res = await _api.submit(episode, draft, clientId: await clientId());
      if (value.episode?.key == episode.key) {
        _set(value.copyWith(phase: SegmentsPhase.ready, segments: res.segments, submitted: res.submitted));
      }
      unawaited(_writeCache(episode.key, res));
      return SegmentSubmitResult(true, '已共享「${draft.category.label}」，谢谢！');
    } on SegmentsException catch (e) {
      if (e.code == 'already_submitted' && value.episode?.key == episode.key) {
        _set(value.copyWith(submitted: {...value.submitted, draft.category}));
      }
      return SegmentSubmitResult(false, e.message);
    }
  }

  /// 上报自动执行后的反馈（失败静默，不影响播放）。
  ///
  /// 服务端判定撤下（异议 ≥ 2 且 ≥ 认可）时，本地也立刻移除该片段并作废缓存，
  /// 这一集该分类重新开放提交。
  ///
  /// [episodeKey] 是**执行该片段时**那一集的键（由执行器记下）：提示结束时可能已经换集 /
  /// 退出播放，不能再读当前状态，否则反馈会被静默丢掉（2026-10-27 实机「撤销不生效」根因）。
  /// 网络失败重试一次。无论结果如何都作废该集缓存：下次播放从服务端拿最新结果。
  Future<void> feedback(SharedSegment segment, {required bool disputed, String? episodeKey}) async {
    final key = episodeKey ?? value.episode?.key;
    if (key == null) return;
    bool? hidden;
    for (var attempt = 0; attempt < 2 && hidden == null; attempt++) {
      try {
        hidden = await _api.feedback(key, segment, disputed: disputed, clientId: await clientId());
      } on SegmentsException catch (e) {
        if (e.code == 'segment_gone') hidden = true; // 别人已经撤下：本地同样移除
        if (e.code != null && e.code != 'segment_gone') break; // 业务拒绝（400 / 429）不重试
        if (attempt == 0 && hidden == null) await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    try {
      await _cacheFile(key).delete();
    } catch (_) {}
    if (hidden == true && value.episode?.key == key) {
      _set(value.copyWith(segments: value.segments.where((s) => s.id != segment.id).toList()));
    }
  }

  void clear() {
    _epoch++;
    if (value.phase != SegmentsPhase.idle) _set(const SegmentsState());
  }

  Future<SegmentsResponse?> _readCache(String key, {required bool fresh}) async {
    try {
      final f = _cacheFile(key);
      if (!await f.exists()) return null;
      if (fresh && DateTime.now().difference(await f.lastModified()) > cacheTtl) return null;
      return SegmentsResponse.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String key, SegmentsResponse res) async {
    try {
      final f = _cacheFile(key);
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'segments': [
          for (final s in res.segments)
            {
              'category': s.category.key,
              'action': s.action.key,
              'startMs': s.startMs,
              'endMs': s.endMs,
              'durationMs': s.durationMs,
              'votes': s.votes,
              'total': s.total,
            }
        ],
        'submitted': [for (final c in res.submitted) c.key],
      }));
      await tmp.rename(f.path);
    } catch (_) {}
  }

  void _set(SegmentsState s) {
    if (!_disposed) value = s;
  }

  @override
  void dispose() {
    _disposed = true;
    _api.close();
    super.dispose();
  }
}
