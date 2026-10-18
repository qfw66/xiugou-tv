import 'dart:async';

import '../api/models/vod_models.dart';
import 'line_switch_planner.dart';
import 'models/player_state.dart';
import 'playback_error_text.dart';
import 'player_engine.dart';

typedef AutoSwitchCanSwitch = bool Function(int epoch);
typedef AutoSwitchAttempt = Future<bool> Function(
    LineCandidate candidate, Duration position, int epoch);
typedef AutoSwitchNotice = void Function(String message);

/// 早期播放错误自动换线控制器（SET-12）。
///
/// 只负责「何时换、候选是谁」；真正的解析 / 启动 / 历史更新由宿主通过
/// [onCandidate] 完成。这样控制器可以用假引擎做纯单元测试。
class AutoLineSwitchController {
  final PlayerEngine engine;
  final AutoSwitchCanSwitch canSwitch;
  final AutoSwitchAttempt onCandidate;
  final AutoSwitchNotice onNotice;
  final void Function(bool busy)? onBusyChanged;
  final Duration debounce;
  final Duration earlyWindow;

  /// 位置推进多少才算「还能播」：误差抖动（seek 过渡期 ±0.2s）不算。
  final Duration progressThreshold;

  StreamSubscription<PlaybackStatus>? _statusSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _timer;
  _ArmedState? _armed;
  bool _inFlight = false;
  bool _disposed = false;

  AutoLineSwitchController({
    required this.engine,
    required this.canSwitch,
    required this.onCandidate,
    required this.onNotice,
    this.onBusyChanged,
    this.debounce = const Duration(seconds: 2),
    this.earlyWindow = const Duration(seconds: 15),
    this.progressThreshold = const Duration(seconds: 1),
  });

  bool get isArmed => _armed != null;
  bool get isBusy => _inFlight;

  /// 在新播放会话建立后调用；会替换上一份会话状态。
  void arm({
    required List<PlayFrom> sources,
    required int currentSourceIndex,
    required String currentSourceName,
    required String episodeName,
    required String currentEpisodeUrl,
    required Set<String> tried,
    required int epoch,
    Duration startPosition = Duration.zero,
  }) {
    if (_disposed) return;
    _cancelTimer();
    if (sources.length <= 1) {
      _armed = null;
      return;
    }
    _armed = _ArmedState(
      sources: List.unmodifiable(sources),
      currentSourceIndex: currentSourceIndex,
      currentSourceName: currentSourceName,
      episodeName: episodeName,
      currentEpisodeUrl: currentEpisodeUrl,
      tried: Set.unmodifiable(tried),
      epoch: epoch,
      startPosition: startPosition,
    );
    _ensureSubscribed();
    if (engine.status == PlaybackStatus.error &&
        engine.position < startPosition + earlyWindow) {
      _scheduleAttempt();
    }
  }

  /// 永久性错误（域名不解析 / HTTP 4xx-5xx / 格式不支持）重试无意义：
  /// 跳过防抖立即换线；其余（瞬时 / 未知）保留防抖，给「其实还能播」留窗口。
  void _scheduleAttempt() {
    final kind = classifyPlaybackFailure(engine.currentError).kind;
    if (kind == PlaybackFailureKind.permanent) {
      unawaited(_attempt());
      return;
    }
    _timer ??= Timer(debounce, _attempt);
  }

  /// 关闭播放 / 切换会话 / 刷新开始时调用。
  void disarm() {
    _cancelTimer();
    _armed = null;
  }

  void _ensureSubscribed() {
    _statusSubscription ??= engine.statusStream.listen(_onStatus);
    _positionSubscription ??= engine.positionStream.listen(_onPosition);
  }

  void _onStatus(PlaybackStatus status) {
    final armed = _armed;
    if (armed == null || _inFlight || _disposed) return;
    if (status == PlaybackStatus.error) {
      if (engine.position >= armed.startPosition + earlyWindow) return;
      _scheduleAttempt();
    } else if (status == PlaybackStatus.playing) {
      // 注意：引擎在 error 后会锁存状态，同一次播放内通常不会再发 playing；
      // 真正的兜底是 `_onPosition` 的「位置前进即取消」。这里保留分支以防
      // 引擎未来解除锁存。
      _cancelTimer();
    }
  }

  void _onPosition(Duration position) {
    final armed = _armed;
    if (armed == null) return;
    if (position >= armed.startPosition + earlyWindow) {
      // 已经看到有效内容：晚期错误不再自动换线。
      _cancelTimer();
      _armed = null;
      return;
    }
    if (_timer != null &&
        position >= armed.startPosition + progressThreshold) {
      // 错误后位置确实前进（≥1s）：说明还能播，取消本次换线。
      _cancelTimer();
    }
  }

  Future<void> _attempt() async {
    _timer = null;
    final armed = _armed;
    if (armed == null || _inFlight || _disposed) return;
    if (!canSwitch(armed.epoch)) return;

    final position = engine.position;
    if (position >= armed.startPosition + earlyWindow) return;

    final candidates = planLineCandidates(
      sources: armed.sources,
      currentSourceIndex: armed.currentSourceIndex,
      episodeName: armed.episodeName,
      currentEpisodeUrl: armed.currentEpisodeUrl,
      tried: armed.tried,
    );
    if (candidates.isEmpty) {
      onNotice('所有备用线路均不可用，请稍后重试，或返回列表重新选择影片换线');
      return;
    }

    _inFlight = true;
    onBusyChanged?.call(true);
    try {
      final tried = {...armed.tried};
      for (final candidate in candidates) {
        if (!canSwitch(armed.epoch)) return;
        final basis = candidate.matchedBy == LineMatchKind.normalizedName
            ? '（集名归一化匹配）'
            : '';
        onNotice('线路「${armed.currentSourceName}」不可用，'
            '正在尝试「${candidate.source.name}」$basis…');
        final switched =
            await onCandidate(candidate, position, armed.epoch);
        if (!canSwitch(armed.epoch)) return;
        tried.add(candidate.key);
        _armed = armed.copyWith(tried: {...tried});
        if (switched) {
          _armed = armed.copyWith(
            currentSourceIndex: candidate.sourceIndex,
            currentSourceName: candidate.source.name,
            currentEpisodeUrl: candidate.episode.url,
            tried: {...tried},
          );
          return;
        }
      }
      onNotice('所有备用线路均不可用，请稍后重试，或返回列表重新选择影片换线');
    } finally {
      _inFlight = false;
      onBusyChanged?.call(false);
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    _cancelTimer();
    _armed = null;
    _statusSubscription?.cancel();
    _positionSubscription?.cancel();
    _statusSubscription = null;
    _positionSubscription = null;
  }
}

class _ArmedState {
  final List<PlayFrom> sources;
  final int currentSourceIndex;
  final String currentSourceName;
  final String episodeName;
  final String currentEpisodeUrl;
  final Set<String> tried;
  final int epoch;
  final Duration startPosition;

  const _ArmedState({
    required this.sources,
    required this.currentSourceIndex,
    required this.currentSourceName,
    required this.episodeName,
    required this.currentEpisodeUrl,
    required this.tried,
    required this.epoch,
    required this.startPosition,
  });

  _ArmedState copyWith({
    int? currentSourceIndex,
    String? currentSourceName,
    String? currentEpisodeUrl,
    Set<String>? tried,
  }) {
    return _ArmedState(
      sources: sources,
      currentSourceIndex: currentSourceIndex ?? this.currentSourceIndex,
      currentSourceName: currentSourceName ?? this.currentSourceName,
      episodeName: episodeName,
      currentEpisodeUrl: currentEpisodeUrl ?? this.currentEpisodeUrl,
      tried: tried ?? this.tried,
      epoch: epoch,
      startPosition: startPosition,
    );
  }
}
