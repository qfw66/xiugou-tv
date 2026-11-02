import 'dart:async';

import 'package:flutter/foundation.dart';

import 'danmaku_api.dart';
import 'danmaku_cache.dart';
import 'danmaku_matcher.dart';
import 'danmaku_models.dart';

enum DanmakuLoadPhase { idle, searching, loading, ready, none, failed }

/// 弹幕加载状态（给播放器按钮 / 提示用）。
@immutable
class DanmakuState {
  const DanmakuState({
    this.phase = DanmakuLoadPhase.idle,
    this.track,
    this.candidate,
    this.message,
    this.requestKey,
  });

  final DanmakuLoadPhase phase;
  final DanmakuTrack? track;
  final DanmakuCandidate? candidate;

  /// 失败 / 无弹幕时的说明
  final String? message;

  /// 当前请求标识（见 [DanmakuController.keyOf]）：用于丢弃过期结果与去重
  final String? requestKey;

  bool get busy => phase == DanmakuLoadPhase.searching || phase == DanmakuLoadPhase.loading;

  /// 简短状态文案（按钮 tooltip / OSD）。不含弹幕条数（§43：播放页不显示总数）。
  String get label => switch (phase) {
        DanmakuLoadPhase.idle => '弹幕',
        DanmakuLoadPhase.searching => '正在匹配弹幕…',
        DanmakuLoadPhase.loading => '正在加载弹幕…',
        DanmakuLoadPhase.ready => '弹幕已加载',
        DanmakuLoadPhase.none => message ?? '未找到弹幕',
        DanmakuLoadPhase.failed => message ?? '弹幕加载失败',
      };
}

/// 按播放会话加载弹幕：起播 / 换集时 [load]，换线 / 退出时 [clear]。
///
/// - 候选经 [DanmakuMatcher] 校验，片名 / 季 / 集号不一致的一律不用；
/// - 同一会话同一集（见 [keyOf]）重复调用只加载一次（换线不重拉）；
/// - 新请求会取消旧请求，旧结果到达后丢弃；
/// - 弹幕原文落盘缓存（键见 [cacheKeyOf]），命中时不走网络；
/// - 任何失败只改状态，不抛到播放流程。
class DanmakuController extends ValueNotifier<DanmakuState> {
  DanmakuController({required DanmakuApi api, DanmakuCache? cache})
      : _api = api,
        _cache = cache,
        super(const DanmakuState());

  final DanmakuApi _api;
  final DanmakuCache? _cache;
  DanmakuCancelToken? _token;
  bool _disposed = false;

  /// 请求标识：播放会话范围（站点 + 影片 id）+ 规范化片名 + 季 + 集号。
  ///
  /// 换线（同片同集）标识不变、不重拉；同名不同站点 / 不同影片、或同片不同集都会重新匹配。
  static String keyOf(DanmakuQuery query, {String scope = ''}) => '$scope#${query.identity}';

  /// 磁盘缓存键：候选名（含片名 / 年份 / 平台 / 集数）+ 取数地址。
  ///
  /// 服务端的分集 id（`comment/10283`）来自其内存缓存，实例重启后会重新分配给别的片 / 别的集；
  /// 只按地址缓存会把旧文件当成新候选的弹幕（串片 / 串集），所以必须连同候选名一起作键。
  static String cacheKeyOf(DanmakuCandidate candidate) => '${candidate.name}|${candidate.jsonUrl}';

  /// 加载当前集弹幕。
  ///
  /// [episodeIndex] / [episodeCount] 来自选集列表（单集 = 电影，多集认不出集号则不匹配）；
  /// [yearHint] 为站源年份（只参与排序）；[scope] 区分播放会话（建议「站点 key|影片 id」）。
  Future<void> load({
    required String name,
    required String episode,
    int? episodeIndex,
    int? episodeCount,
    String? yearHint,
    String scope = '',
  }) async {
    if (name.trim().isEmpty) {
      clear();
      return;
    }
    final query = DanmakuQuery(
        name: name,
        episode: episode,
        episodeIndex: episodeIndex,
        episodeCount: episodeCount,
        yearHint: yearHint);
    final key = keyOf(query, scope: scope);
    if (value.requestKey == key &&
        (value.busy ||
            value.phase == DanmakuLoadPhase.ready ||
            value.phase == DanmakuLoadPhase.none)) {
      return;
    }

    _token?.cancel();
    final token = _token = DanmakuCancelToken();
    // 结果只在「仍是当前请求」时落到状态上：换集 / 换片 / 清空后晚到的结果一律丢弃
    bool stale() => token.isCancelled || !identical(_token, token);
    _set(DanmakuState(phase: DanmakuLoadPhase.searching, requestKey: key));

    try {
      if (query.episodeUnresolved) {
        _log('「$name」集名「$episode」认不出集号，不加载弹幕');
        _set(DanmakuState(phase: DanmakuLoadPhase.none, requestKey: key, message: '未找到匹配弹幕（无法识别集数）'));
        return;
      }
      final candidates = await _api.search(query.searchName, query.searchEpisode, cancel: token);
      if (stale()) return;
      if (candidates.isEmpty) {
        _log('「${query.searchName}」${query.searchEpisode}：服务端无候选');
        _set(DanmakuState(phase: DanmakuLoadPhase.none, requestKey: key, message: '未找到弹幕'));
        return;
      }
      // 服务端按模糊相似度排序，首位可能是另一部片（「繁花」→《星绽繁花》）或别的集（认不出集名时退回第 1 集）：
      // 只用片名 / 季 / 集号都核对一致的候选，宁可不显示也不显示错的弹幕
      final matched = DanmakuMatcher.select(query, candidates);
      if (matched.isEmpty) {
        _log('「$name」「$episode」→ 第${query.episodeNumber ?? '?'}集：${candidates.length} 个候选均不匹配，'
            '服务端首位「${candidates.first.name}」');
        _set(DanmakuState(phase: DanmakuLoadPhase.none, requestKey: key, message: '未找到匹配弹幕'));
        return;
      }
      final candidate = matched.first;
      _log('「$name」「$episode」→ 选用「${candidate.name}」（${matched.length}/${candidates.length} 个候选通过校验）');
      _set(DanmakuState(phase: DanmakuLoadPhase.loading, requestKey: key, candidate: candidate));

      final cacheKey = cacheKeyOf(candidate);
      var body = await _cache?.read(cacheKey);
      if (stale()) return;
      final fromCache = body != null;
      body ??= await _api.fetchComments(candidate, cancel: token);
      if (stale()) return;

      final track = await compute(DanmakuTrack.fromJsonString, body);
      if (stale()) return;
      if (track.isEmpty) {
        _set(DanmakuState(
            phase: DanmakuLoadPhase.none, requestKey: key, candidate: candidate, message: '这一集暂无弹幕'));
        return;
      }
      if (!fromCache) unawaited(_cache?.write(cacheKey, body));
      _set(DanmakuState(
          phase: DanmakuLoadPhase.ready, requestKey: key, candidate: candidate, track: track));
    } on DanmakuException catch (e) {
      if (stale()) return;
      _set(DanmakuState(
          phase: e.message == '无弹幕' ? DanmakuLoadPhase.none : DanmakuLoadPhase.failed,
          requestKey: key,
          message: e.message));
    } catch (e) {
      if (stale()) return;
      _set(DanmakuState(phase: DanmakuLoadPhase.failed, requestKey: key, message: '弹幕解析失败'));
    }
  }

  /// 诊断日志：只记片名 / 集名 / 候选名，不记服务地址（地址里带访问令牌）。
  static void _log(String message) => debugPrint('[danmaku] $message');

  /// 取消在途请求并清空（退出播放 / 直播 / 关闭弹幕时）。
  void clear() {
    _token?.cancel();
    _token = null;
    _set(const DanmakuState());
  }

  void _set(DanmakuState state) {
    if (!_disposed) value = state;
  }

  @override
  void dispose() {
    _disposed = true;
    _token?.cancel();
    // 与 SegmentsController 对齐：控制器持有 api，释放时一并关掉其 HttpClient
    // （强制断开在途连接与空闲连接池；2026-10-28 发布前资源审查）。
    _api.close();
    super.dispose();
  }
}
