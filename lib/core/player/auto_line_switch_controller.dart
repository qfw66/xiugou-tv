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

/// 同站线路耗尽后的接管回调。
///
/// 参数：当前 epoch、调用时的最新播放位置。返回 true 表示上层已经接管
/// 提示（例如开始跨站搜索），控制器不再发送默认的「所有备用线路均不可用」。
typedef AutoSwitchExhausted = bool Function(int epoch, Duration position);

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

  /// §14 用户开关：返回 false 时 [arm] 不建立会话，出错只走常规提示。
  /// 每次 arm 时现读，设置页改动对下一次起播立即生效。
  final bool Function()? isEnabled;

  /// 同站线路耗尽时调用；为 null 时完全保持原行为（单线路也不 arm）。
  final AutoSwitchExhausted? onSameSiteExhausted;
  final Duration debounce;
  final Duration earlyWindow;

  /// 位置推进多少才算「还能播」：误差抖动（seek 过渡期 ±0.2s）不算。
  final Duration progressThreshold;

  StreamSubscription<PlaybackStatus>? _statusSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _timer;

  /// 排队换线时的播放位置：「错误后位置前进」要从这里算，不能从起播位置算。
  Duration? _timerBase;

  /// 本控制器最近一次从位置流收到的位置（arm 时清空）。
  /// 出错基准用它而不用 `engine.position`：后者可能已包含尚未投递到这里的
  /// 「出错之后」的位置，会把基准抬高、让真正的恢复判不出来。
  Duration? _lastSeenPosition;
  _ArmedState? _armed;
  bool _inFlight = false;
  bool _attemptPending = false;
  bool _disposed = false;
  bool _exhaustedReported = false;

  /// 会话代际：arm / disarm / dispose 时递增，防止旧的在途尝试误触发回调。
  int _session = 0;

  AutoLineSwitchController({
    required this.engine,
    required this.canSwitch,
    required this.onCandidate,
    required this.onNotice,
    this.onBusyChanged,
    this.isEnabled,
    this.onSameSiteExhausted,
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
    _session++;
    _exhaustedReported = false;
    _cancelTimer();
    _attemptPending = false;
    // 单线路默认不 arm；只有上层提供接管回调时，单线路也值得在失败后
    // 通知一次（P0（2）跨站故障转移的入口）。
    final canReportExhausted =
        sources.length > 1 || onSameSiteExhausted != null;
    if (sources.isEmpty || !canReportExhausted || isEnabled?.call() == false) {
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
    _lastSeenPosition = null;
    _ensureSubscribed();
    if (engine.status == PlaybackStatus.error &&
        engine.position < startPosition + earlyWindow) {
      _scheduleAttempt(_later(startPosition, engine.position));
    }
  }

  /// 恢复切集等临时忙碌态后，继续已到期但被互斥守卫挡下的尝试。
  void resumePendingAttempt() {
    if (!_attemptPending || _disposed || _inFlight) return;
    _attemptPending = false;
    unawaited(_attempt());
  }

  /// 永久性错误（域名不解析 / HTTP 4xx-5xx / 格式不支持）重试无意义：
  /// 跳过防抖立即换线；其余（瞬时 / 未知）保留防抖，给「其实还能播」留窗口。
  ///
  /// [base]：出错时的播放位置，之后位置比它前进 [progressThreshold] 才算「还能播」。
  void _scheduleAttempt(Duration base) {
    final kind = classifyPlaybackFailure(engine.currentError).kind;
    if (kind == PlaybackFailureKind.permanent) {
      unawaited(_attempt());
      return;
    }
    if (_timer != null) return;
    _timerBase = base;
    _timer = Timer(debounce, _attempt);
  }

  static Duration _later(Duration a, Duration b) => a >= b ? a : b;

  /// 当前播放内容未变、仅异步事务推进代际时重绑定 epoch。
  /// 保留原起播位置、已尝试线路和候选状态，避免失败恢复时重开 15 秒窗口。
  void rebindEpoch(int epoch) {
    final armed = _armed;
    if (armed == null || _disposed) return;
    _armed = armed.copyWith(epoch: epoch);
  }

  /// 关闭播放 / 切换会话 / 刷新开始时调用。
  void disarm() {
    _session++;
    _exhaustedReported = false;
    _cancelTimer();
    _attemptPending = false;
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
      // 基准不低于起播位置：续播 seek 到位前就报错时，与原口径一致。
      _scheduleAttempt(_later(
          armed.startPosition, _lastSeenPosition ?? armed.startPosition));
    } else if (status == PlaybackStatus.playing) {
      // 注意：引擎在 error 后会锁存状态，同一次播放内通常不会再发 playing；
      // 真正的兜底是 `_onPosition` 的「位置前进即取消」。这里保留分支以防
      // 引擎未来解除锁存。
      _cancelTimer();
    }
  }

  void _onPosition(Duration position) {
    _lastSeenPosition = position;
    final armed = _armed;
    if (armed == null) return;
    if (position >= armed.startPosition + earlyWindow) {
      // 已经看到有效内容：晚期错误不再自动换线。
      _cancelTimer();
      _armed = null;
      return;
    }
    final base = _timerBase;
    if (_timer != null && base != null && position >= base + progressThreshold) {
      // 错误后位置确实前进（≥1s）：说明还能播，取消本次换线。
      // 基准是出错（排队）时的位置：起播已播了几秒才报错时，出错后残余的
      // 位置回调不能当成「恢复播放」把换线取消（2026-11-05 回归）。
      _cancelTimer();
    }
  }

  Future<void> _attempt() async {
    _timer = null;
    _timerBase = null;
    final armed = _armed;
    if (armed == null || _inFlight || _disposed) return;
    if (!canSwitch(armed.epoch)) {
      // Timer is already elapsed. Keep the intent so a transient switching gate
      // cannot consume the only error event from the engine.
      _attemptPending = true;
      return;
    }

    final position = engine.position;
    if (position >= armed.startPosition + earlyWindow) return;

    final session = _session;
    final exhausted = onSameSiteExhausted;
    final candidates = planLineCandidates(
      sources: armed.sources,
      currentSourceIndex: armed.currentSourceIndex,
      episodeName: armed.episodeName,
      currentEpisodeUrl: armed.currentEpisodeUrl,
      tried: armed.tried,
    );
    if (candidates.isEmpty) {
      if (exhausted == null) {
        onNotice(_defaultExhaustedNotice(armed));
        return;
      }
      _reportSameSiteExhausted(armed, session);
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
        final switched = await onCandidate(candidate, position, armed.epoch);
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
      if (exhausted == null) {
        onNotice(_defaultExhaustedNotice(armed));
      }
    } finally {
      _inFlight = false;
      onBusyChanged?.call(false);
    }

    // 只有候选循环自然结束才走到这里；成功 / canSwitch 失效都会在 try 内
    // return。此时 busy 已在 finally 复位，上层可以安全弹框或开始跨站搜索。
    if (exhausted != null && session == _session && !_disposed) {
      _reportSameSiteExhausted(armed, session);
    }
  }

  /// 同站线路真正耗尽后的唯一出口：每次会话最多回调一次。
  void _reportSameSiteExhausted(_ArmedState armed, int session) {
    if (_exhaustedReported || _disposed) return;
    if (session != _session || _armed == null) return;
    final callback = onSameSiteExhausted;
    if (callback == null) {
      onNotice(_defaultExhaustedNotice(armed));
      return;
    }
    _exhaustedReported = true;
    var handled = false;
    try {
      handled = callback(armed.epoch, engine.position);
    } catch (_) {
      // 上层的提示 / 搜索逻辑不能影响控制器的 busy 复位与后续会话。
      handled = false;
    }
    // 回调里可能已经 arm 新会话或 disarm；旧会话不应再补默认提示。
    if (_disposed || session != _session || _armed == null) return;
    if (!handled) onNotice(_defaultExhaustedNotice(armed));
  }

  String _defaultExhaustedNotice(_ArmedState armed) {
    if (armed.sources.length <= 1) {
      return '当前线路不可用，请稍后重试，或返回列表重新选择影片换线';
    }
    return '所有备用线路均不可用，请稍后重试，或返回列表重新选择影片换线';
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _timerBase = null;
  }

  void dispose() {
    _disposed = true;
    _session++;
    _exhaustedReported = false;
    _cancelTimer();
    _attemptPending = false;
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
    int? epoch,
  }) {
    return _ArmedState(
      sources: sources,
      currentSourceIndex: currentSourceIndex ?? this.currentSourceIndex,
      currentSourceName: currentSourceName ?? this.currentSourceName,
      episodeName: episodeName,
      currentEpisodeUrl: currentEpisodeUrl ?? this.currentEpisodeUrl,
      tried: tried ?? this.tried,
      epoch: epoch ?? this.epoch,
      startPosition: startPosition,
    );
  }
}
