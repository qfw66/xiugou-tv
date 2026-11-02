import 'playback_error_text.dart';

/// §56 播放器「错误」的致命性判定。
///
/// 背景：media_kit 把 mpv 里**任何** error 级日志（前缀 vd / ad / stream / cplayer、
/// ffmpeg `tcp:` 等）都推到 `Player.stream.error`。这里面大量是可恢复的：
/// 某帧解码失败、ffmpeg 断线自动重连、HLS 单个分片失败被跳过、外挂字幕打不开……
/// 以前引擎收到第一条就把状态锁成「播放错误」并忽略后续 playing，于是出现
/// 「弹出播放错误，但视频还在正常播放」；起播早期的误报还会触发自动换线。
///
/// 现在的口径：错误先「待定」，到期时看播放位置有没有继续推进——推进了就当作
/// 非致命（只记诊断日志）；没推进才确认为致命。确认后若位置又持续推进，解除错误态。
///
/// 纯逻辑，不依赖原生 mpv；计时由调用方（[MpvPlayerEngine]）负责。
class PlaybackErrorGate {
  /// 一般错误的确认等待。
  final Duration confirmWindow;

  /// 起播前（媒体还没打开、位置没推进过）遇到永久性错误（404 / 域名不解析等）的确认等待：
  /// 坏线路要尽快报错 / 换线，不能每条都多等 3 秒。
  final Duration fastWindow;

  /// 待定期间位置推进超过它，即判为非致命。
  final Duration progressThreshold;

  /// 确认致命后位置又推进超过它，即判为已恢复。
  final Duration recoverThreshold;

  PlaybackErrorGate({
    this.confirmWindow = const Duration(seconds: 3),
    this.fastWindow = const Duration(seconds: 1),
    this.progressThreshold = const Duration(milliseconds: 500),
    this.recoverThreshold = const Duration(seconds: 1),
  });

  String? _pending;
  Duration _pendingBase = Duration.zero;
  Duration? _committedBase;
  bool _progressed = false;
  Duration? _lastPosition;

  /// 当前待定的错误文本（无则 null）。
  String? get pending => _pending;

  /// 新会话 / 重新打开媒体时清空。
  void reset() {
    _pending = null;
    _pendingBase = Duration.zero;
    _committedBase = null;
    _progressed = false;
    _lastPosition = null;
  }

  /// 每次位置回调都要喂进来：用于判断「本次打开后是否真的播起来过」。
  void onPosition(Duration position) {
    final last = _lastPosition;
    if (last != null && position > last) _progressed = true;
    _lastPosition = position;
  }

  /// 收到一条候选错误。返回需要等待的时长，到期后调用 [resolve]；
  /// 已有待定错误时只更新文本、沿用原计时，返回 null。
  Duration? onError(String error,
      {required Duration position, required bool mediaOpened}) {
    if (_pending != null) {
      _pending = error;
      return null;
    }
    _pending = error;
    _pendingBase = position;
    final permanent =
        classifyPlaybackFailure(error).kind == PlaybackFailureKind.permanent;
    return permanent && !_progressed && !mediaOpened ? fastWindow : confirmWindow;
  }

  /// 计时到期：返回应确认的致命错误；返回 null 表示播放仍在推进、按非致命忽略。
  String? resolve({required Duration position}) {
    final error = _pending;
    _pending = null;
    if (error == null) return null;
    if (position - _pendingBase >= progressThreshold) return null;
    _committedBase = position;
    return error;
  }

  /// 错误已确认后，位置继续推进到阈值以上：返回 true 表示应解除错误态（只触发一次）。
  bool recovered(Duration position) {
    final base = _committedBase;
    if (base == null) return false;
    if (position - base < recoverThreshold) return false;
    _committedBase = null;
    return true;
  }
}
