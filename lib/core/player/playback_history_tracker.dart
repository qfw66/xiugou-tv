import 'dart:async';

import '../config/config_repository.dart';
import 'models/player_state.dart';
import 'player_engine.dart';

/// 播放历史进度跟踪器：把播放引擎的实时位置持续写回对应的历史记录，
/// 为断点续播与历史列表进度条提供数据。
///
/// 写入策略：
/// - 播放位置每前进/后退超过 [saveInterval] 落盘一次（按播放位置差节流，与墙钟无关）；
/// - 暂停、播放完成、[stop] 时立即写入最终位置；
/// - 未调用 [track] 或已 [stop] 时忽略引擎事件（直播 / 推送直链不进历史）。
class PlaybackHistoryTracker {
  final PlayerEngine _engine;
  final ConfigRepository _repository;
  final Duration saveInterval;

  String? _activeRecordId;
  Duration? _lastSavedPosition;

  /// 位置下限：非空时忽略低于该值的位置事件与落盘（刷新重载后的 seek 过渡期），
  /// 位置越过下限后自动清空，恢复正常落盘。
  Duration? _positionFloor;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;

  PlaybackHistoryTracker({
    required PlayerEngine engine,
    required ConfigRepository repository,
    this.saveInterval = const Duration(seconds: 5),
  })  : _engine = engine,
        _repository = repository;

  /// 当前正在跟踪的历史记录 ID（未跟踪时为 null）
  String? get activeRecordId => _activeRecordId;

  /// 开始跟踪指定历史记录；切换记录前会先把上一条的进度刷入。
  ///
  /// [flushPrevious] 为 false 时丢弃上一条的待写进度：用于启动失败 / 会话作废，
  /// 此时引擎位置属于另一条记录，写入会造成进度错位。
  /// [recordId] 为 null 表示停止跟踪，且不写入任何进度。
  /// [baseline] 记录「已落盘位置」的基线（用于刷新重载后跳过 seek 过渡期的回退事件）。
  /// [floor] 位置下限（低于该值的事件与落盘一律忽略，越过下限后自动解除）。
  void track(String? recordId,
      {bool flushPrevious = true, Duration? baseline, Duration? floor}) {
    if (_disposed) return;
    if (flushPrevious && _activeRecordId != null && _activeRecordId != recordId) {
      unawaited(flush());
    }
    _activeRecordId = recordId;
    _lastSavedPosition = baseline;
    _positionFloor = floor;
    _ensureSubscribed();
  }

  /// 停止跟踪：写入最终进度并清除当前记录。
  ///
  /// 位置快照在方法同步阶段捕获，因此调用方可紧接着调用 `engine.stop()`
  /// 而不会丢失最后的播放位置。
  Future<void> stop() async {
    final pending = flush();
    _activeRecordId = null;
    _lastSavedPosition = null;
    _positionFloor = null;
    await pending;
  }

  /// 立即把当前播放位置写入活动记录（无活动记录或位置为 0 时不写）。
  Future<void> flush() {
    final recordId = _activeRecordId;
    if (recordId == null) return Future.value();
    final position = _engine.position;
    final duration = _engine.duration;
    if (position <= Duration.zero) return Future.value();
    final floor = _positionFloor;
    if (floor != null && position < floor) return Future.value();
    _lastSavedPosition = position;
    return _writeProgress(recordId, position, duration);
  }

  void _ensureSubscribed() {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.add(_engine.positionStream.listen(_onPosition));
    _subscriptions.add(_engine.statusStream.listen(_onStatus));
  }

  void _onPosition(Duration position) {
    final recordId = _activeRecordId;
    if (recordId == null || position <= Duration.zero) return;

    final floor = _positionFloor;
    if (floor != null) {
      if (position < floor) return; // 重载后的 seek 过渡事件：忽略，避免断点被改小
      _positionFloor = null; // 已越过基线，恢复正常落盘
    }

    final last = _lastSavedPosition;
    final delta = last == null ? position : (position - last).abs();
    if (last != null && delta < saveInterval) return;

    _lastSavedPosition = position;
    unawaited(_writeProgress(recordId, position, _engine.duration));
  }

  void _onStatus(PlaybackStatus status) {
    if (_activeRecordId == null) return;
    switch (status) {
      case PlaybackStatus.paused:
      case PlaybackStatus.completed:
        unawaited(flush());
        break;
      case PlaybackStatus.idle:
      case PlaybackStatus.buffering:
      case PlaybackStatus.playing:
      case PlaybackStatus.error:
        break;
    }
  }

  Future<void> _writeProgress(String recordId, Duration position, Duration duration) async {
    try {
      await _repository.updateHistoryProgress(
        recordId,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
      );
    } catch (_) {
      // 进度落盘失败不应影响播放；下一次节流点会再次尝试
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }
}
