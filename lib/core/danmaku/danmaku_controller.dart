import 'dart:async';

import 'package:flutter/foundation.dart';

import 'danmaku_api.dart';
import 'danmaku_cache.dart';
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

  /// 当前请求对应的「片名|集名」：用于丢弃过期结果与去重
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
/// - 同一「片名|集名」重复调用只加载一次（换线不重拉）；
/// - 新请求会取消旧请求，旧结果到达后丢弃；
/// - 弹幕原文落盘缓存，命中时不走网络；
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

  static String keyOf(String name, String episode) => '${name.trim()}|${episode.trim()}';

  Future<void> load({required String name, required String episode}) async {
    final key = keyOf(name, episode);
    if (name.trim().isEmpty) {
      clear();
      return;
    }
    if (value.requestKey == key && (value.busy || value.phase == DanmakuLoadPhase.ready)) return;

    _token?.cancel();
    final token = _token = DanmakuCancelToken();
    _set(DanmakuState(phase: DanmakuLoadPhase.searching, requestKey: key));

    try {
      final candidates = await _api.search(name.trim(), episode.trim(), cancel: token);
      if (token.isCancelled) return;
      if (candidates.isEmpty) {
        _set(DanmakuState(phase: DanmakuLoadPhase.none, requestKey: key, message: '未找到弹幕'));
        return;
      }
      final candidate = candidates.first;
      _set(DanmakuState(phase: DanmakuLoadPhase.loading, requestKey: key, candidate: candidate));

      var body = await _cache?.read(candidate.jsonUrl);
      final fromCache = body != null;
      body ??= await _api.fetchComments(candidate, cancel: token);
      if (token.isCancelled) return;

      final track = await compute(DanmakuTrack.fromJsonString, body);
      if (token.isCancelled) return;
      if (track.isEmpty) {
        _set(DanmakuState(
            phase: DanmakuLoadPhase.none, requestKey: key, candidate: candidate, message: '这一集暂无弹幕'));
        return;
      }
      if (!fromCache) unawaited(_cache?.write(candidate.jsonUrl, body));
      _set(DanmakuState(
          phase: DanmakuLoadPhase.ready, requestKey: key, candidate: candidate, track: track));
    } on DanmakuException catch (e) {
      if (token.isCancelled) return;
      _set(DanmakuState(
          phase: e.message == '无弹幕' ? DanmakuLoadPhase.none : DanmakuLoadPhase.failed,
          requestKey: key,
          message: e.message));
    } catch (e) {
      if (token.isCancelled) return;
      _set(DanmakuState(phase: DanmakuLoadPhase.failed, requestKey: key, message: '弹幕解析失败'));
    }
  }

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
    super.dispose();
  }
}
