import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'decode_diagnostics.dart';
import 'live_stream_tuning.dart';
import 'models/player_settings.dart';
import 'models/player_state.dart';
import 'models/track_info.dart';
import 'playback_diagnostics.dart';
import 'playback_error_gate.dart';
import 'playback_error_text.dart';
import 'playback_http_headers.dart';
import 'player_engine.dart';
import 'player_track_capabilities.dart';
import 'player_settings_application.dart';
import 'mpv_settings_target.dart';
import 'seek_recovery_controller.dart';
import '../danmaku/danmaku_api.dart';

/// 基于 media_kit (libmpv) 的 Windows 平台硬件加速播放引擎实现
class MpvPlayerEngine
    implements
        PlayerEngine,
        VideoTrackCapable,
        SubtitleTrackCapable,
        SeekRecoveryCapable {
  MpvPlayerEngine();

  @visibleForTesting
  static const playerConfiguration = PlayerConfiguration(
    // Independent pitch control uses an audio-only scaletempo path which
    // media_kit warns can desynchronize video. Standard speed keeps A/V synced.
    pitch: false,
    // 播放缓冲 16MB，1080p 约 6~10 秒余量，视码率而定。
    bufferSize: 16 * 1024 * 1024,
    logLevel: MPVLogLevel.warn,
    protocolWhitelist: mpvProtocolWhitelist,
  );

  /// Connects the real engine event handling to an injected media_kit adapter.
  @visibleForTesting
  MpvPlayerEngine.withPlayer(Player player) {
    _player = player;
    _nativeCreated = true;
    _initialization = Future<void>.value();
    _bindNativeStreams();
    unawaited(_observeNativeSeekCompletion());
  }

  late final Player _player;
  late final VideoController _videoController;

  PlaybackStatus _status = PlaybackStatus.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  double _volume = 100.0;
  double _rate = 1.0;
  VideoDimensions _dimensions = const VideoDimensions();
  String? _currentError;
  MediaPlaySpec? _currentSpec;
  /// 已经为这次会话做过「同一地址自动重开」的 spec；同一会话只重试一次。
  MediaPlaySpec? _softRetrySpec;
  List<TrackInfo> _audioTracks = [];
  List<TrackInfo> _subtitleTracks = [];
  List<TrackInfo> _videoTracks = [];

  /// ④ 诊断闭环：mpv 最近日志环形缓冲（40 条），供错误面板展示与「复制诊断」。
  final RecentLogBuffer _recentLogs = RecentLogBuffer();

  final _statusController = StreamController<PlaybackStatus>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferController = StreamController<Duration>.broadcast();
  final _volumeController = StreamController<double>.broadcast();
  final _rateController = StreamController<double>.broadcast();
  final _dimensionsController = StreamController<VideoDimensions>.broadcast();
  final _errorController = StreamController<String?>.broadcast();
  final _audioTracksController = StreamController<List<TrackInfo>>.broadcast();
  final _subtitleTracksController =
      StreamController<List<TrackInfo>>.broadcast();
  final _videoTracksController = StreamController<List<TrackInfo>>.broadcast();

  final List<StreamSubscription> _subscriptions = [];

  /// 直播断流重连：退避计数 + 待执行的重开定时器；[_sessionEpoch] 用于作废
  /// 换台 / 停止之后才到期的旧重连。
  final LiveReconnectPolicy _liveReconnect = LiveReconnectPolicy();
  Timer? _reconnectTimer;
  int _sessionEpoch = 0;

  /// §56 错误致命性判定：mpv 的 error 级日志先待定，到期看位置有没有推进再决定。
  final PlaybackErrorGate _errorGate = PlaybackErrorGate();
  Timer? _errorConfirmTimer;

  final settingsApplication = PlayerSettingsApplication();
  Future<void>? _initialization;
  bool _nativeCreated = false;
  bool _disposed = false;
  bool _pauseIntent = false;
  bool _externalPlaybackPaused = false;
  bool _openingMedia = false;
  bool _awaitingOpenPosition = false;
  bool _sawOpenPosition = false;
  bool _hasOpenLiveFrame = false;
  bool _nativeBuffering = false;
  int _openEpoch = 0;
  String? _openedMediaUri;
  int? _seekEvidenceGeneration;
  final _seekRecovery = SeekRecoveryController();

  @override
  ValueListenable<SeekRecoveryState> get seekRecovery => _seekRecovery;

  /// User pause intent survives buffering and source replacement.
  bool get isPlaybackPaused => _pauseIntent;

  bool get _acceptMediaEvents =>
      !_disposed &&
      _currentSpec != null &&
      !_openingMedia &&
      !_externalPlaybackPaused;

  bool get _hasPendingSeek =>
      _seekRecovery.value.phase != SeekRecoveryPhase.idle;

  bool get _awaitingPausedLiveOpen =>
      _awaitingOpenPosition && _pauseIntent && _currentSpec?.isLive == true;

  // A paused live stream may never advance time or expose a positive duration.
  // Only native evidence for the opened path may certify its decoded frame.
  void _readPendingLiveEvidence() {
    final uri = _openedMediaUri;
    if (!_acceptMediaEvents || !_awaitingPausedLiveOpen || uri == null) return;
    unawaited(_readOpenedMediaEvidence(_sessionEpoch, _openEpoch, uri));
  }

  bool _isCurrentSession(int epoch) => !_disposed && epoch == _sessionEpoch;

  PlayerSettings get playbackSettings => settingsApplication.settings;
  Player get nativePlayer => _player;
  VideoController get videoController => _videoController;

  /// 当前是否关闭视频输出（mpv `vid=no`）；引擎未初始化或回读失败时为 false。
  bool get isVideoDisabled {
    if (!_nativeCreated) return false;
    try {
      return _player.state.track.video.id == 'no';
    } catch (_) {
      return false;
    }
  }

  /// 读取引擎（mpv）版本字符串，用于关于页的运行环境展示。
  ///
  /// 只读诊断信息；引擎未初始化或回读失败时返回 null（调用方显示不可用，不猜值）。
  Future<String?> readEngineVersion() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        return await platform.getProperty('mpv-version');
      }
    } catch (_) {
      // 引擎未初始化（late 字段未赋值）或原生回读失败：返回 null
    }
    return null;
  }

  @override
  Future<void> initialize() {
    if (_disposed) return Future<void>.error(StateError('播放器已关闭'));
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      MediaKit.ensureInitialized();
      _player = Player(configuration: playerConfiguration);
      _nativeCreated = true;
      _videoController = VideoController(_player);
      _bindNativeStreams();
      await _observeNativeSeekCompletion();
      await settingsApplication.attach(MpvSettingsTarget(_player));
      // ④：显式钉住网络连接超时（mpv 默认即 60s）——直播源失联时保证约 60s
      // 内进入错误态并可诊断，而不是无限等待；个别发行版 / 配置可能覆写该值。
      try {
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('network-timeout', '60');
        }
      } catch (_) {
        // 属性不可用时不影响播放主链路。
      }
    } catch (_) {
      settingsApplication.initializationFailed();
      rethrow;
    }
  }

  /// §50 读取实际解码状态（hwdec-current / 编码 / 分辨率）。
  ///
  /// 只读诊断；引擎未初始化或回读失败时返回 null（界面不显示该行，不猜值）。
  Future<DecodeDiagnostics?> readDecodeDiagnostics() async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return null;
      return DecodeDiagnostics(
        requested: playbackSettings.hwdec,
        current: (await platform.getProperty('hwdec-current')).trim(),
        codec: (await platform.getProperty('video-codec')).trim(),
        width: int.tryParse(await platform.getProperty('width')) ?? 0,
        height: int.tryParse(await platform.getProperty('height')) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> applyPlaybackSettings(PlayerSettings settings) =>
      settingsApplication.update(settings);

  void _bindNativeStreams() {
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (!_acceptMediaEvents || _awaitingOpenPosition) return;
        if (_status != PlaybackStatus.error && !_nativeBuffering) {
          _updateStatus(
              playing ? PlaybackStatus.playing : PlaybackStatus.paused);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (!_acceptMediaEvents) return;
        _nativeBuffering = buffering;
        if (buffering && _status != PlaybackStatus.error) {
          _updateStatus(PlaybackStatus.buffering);
        } else if (!buffering &&
            !_awaitingOpenPosition &&
            _status == PlaybackStatus.buffering) {
          _updateStatus(_pauseIntent
              ? PlaybackStatus.paused
              : PlaybackStatus.playing);
        }
        if (!buffering && _pauseIntent) {
          unawaited(_readSettledSeekPosition());
          _readPendingLiveEvidence();
        }
      }),
    );

    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (!_acceptMediaEvents || _hasPendingSeek) return;
        if (completed) {
          // 直播没有「播完」：EOF 即断流，优先自动重连。
          if (_scheduleLiveReconnect()) return;
          _updateStatus(PlaybackStatus.completed);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.position.listen(_publishPosition),
    );

    _subscriptions.add(
      _player.stream.duration.listen(_publishDuration),
    );

    _subscriptions.add(
      _player.stream.buffer.listen((buf) {
        if (!_acceptMediaEvents) return;
        _buffer = buf;
        _bufferController.add(buf);
      }),
    );

    _subscriptions.add(
      _player.stream.volume.listen((vol) {
        _volume = vol;
        _volumeController.add(vol);
      }),
    );

    _subscriptions.add(
      _player.stream.rate.listen((r) {
        _rate = r;
        _rateController.add(r);
      }),
    );

    _subscriptions.add(
      _player.stream.width.listen((w) {
        if (!_acceptMediaEvents) return;
        if (_awaitingPausedLiveOpen) {
          // Player.state may still contain the other dimension of the old file.
          _readPendingLiveEvidence();
          return;
        }
        _dimensions =
            VideoDimensions(width: w ?? 0, height: _player.state.height ?? 0);
        _dimensionsController.add(_dimensions);
      }),
    );

    _subscriptions.add(
      _player.stream.height.listen((h) {
        if (!_acceptMediaEvents) return;
        if (_awaitingPausedLiveOpen) {
          // Player.state may still contain the other dimension of the old file.
          _readPendingLiveEvidence();
          return;
        }
        _dimensions =
            VideoDimensions(width: _player.state.width ?? 0, height: h ?? 0);
        _dimensionsController.add(_dimensions);
      }),
    );

    _subscriptions.add(
      _player.stream.tracks.listen((tracks) {
        if (!_acceptMediaEvents) return;
        _audioTracks = tracks.audio
            .map((t) => TrackInfo(
                  id: t.id,
                  type: TrackType.audio,
                  title: t.title,
                  language: t.language,
                  isSelected: t.id == _player.state.track.audio.id,
                ))
            .toList();
        _audioTracksController.add(_audioTracks);

        _subtitleTracks = tracks.subtitle
            .map((t) => TrackInfo(
                  id: t.id,
                  type: TrackType.subtitle,
                  title: t.title,
                  language: t.language,
                  isSelected: t.id == _player.state.track.subtitle.id,
                ))
            .toList();
        _subtitleTracksController.add(_subtitleTracks);

        _videoTracks = tracks.video
            .where((t) => t.id != 'auto' && t.id != 'no')
            .map((t) => TrackInfo(
                  id: t.id,
                  type: TrackType.video,
                  title: t.title,
                  language: t.language,
                  isSelected: t.id == _player.state.track.video.id,
                ))
            .toList();
        _videoTracksController.add(_videoTracks);
      }),
    );

    _subscriptions.add(
      _player.stream.log.listen((log) {
        _recentLogs.add('[${log.level}] ${log.text}');
      }),
    );

    _subscriptions.add(
      _player.stream.error.listen((err) {
        if (_disposed ||
            _externalPlaybackPaused ||
            _currentSpec == null ||
            err.isEmpty) {
          return;
        }
        if (_hasPendingSeek) {
          _recentLogs.add('[seek-error] $err');
          return;
        }
        // 解码器/缓存降级：mpv 会自动回退继续播放，不能当播放失败（否则「报错但视频正常」）。
        if (isBenignPlaybackError(err)) {
          _recentLogs.add('[benign] 解码/缓存降级，mpv 自动回退，不视为播放失败：$err');
          return;
        }
        _recentLogs.add('[error] $err');
        if (_status == PlaybackStatus.error || _reconnectTimer != null) return;
        final wait = _errorGate.onError(err,
            position: _position,
            mediaOpened: _duration > Duration.zero || _dimensions.width > 0);
        if (wait == null) return;
        final epoch = _sessionEpoch;
        _errorConfirmTimer?.cancel();
        _errorConfirmTimer = Timer(wait, () {
          _errorConfirmTimer = null;
          if (_disposed || epoch != _sessionEpoch) return;
          final fatal = _errorGate.resolve(position: _position);
          if (fatal == null) {
            _recentLogs.add('[nonfatal] 报错后播放仍在推进，按可恢复处理：$err');
            return;
          }
          _commitError(fatal);
        });
      }),
    );
  }

  void _publishPosition(Duration position) {
    if (!_acceptMediaEvents) return;
    _position = position;
    _sawOpenPosition = true;
    _confirmOpenPosition();
    _readPendingLiveEvidence();
    final generation = _seekEvidenceGeneration;
    if (generation != null) {
      if (_pauseIntent && _player.platform is NativePlayer) {
        // A paused time-pos preview is not proof that native seeking settled.
        unawaited(_readSettledSeekPosition());
      } else {
        _seekRecovery.onPosition(position,
            generation: generation,
            isPaused: _pauseIntent,
            isBuffering: _nativeBuffering);
      }
    }
    _liveReconnect.onPosition(position);
    _errorGate.onPosition(position);
    _positionController.add(position);
    if (_status == PlaybackStatus.error && _errorGate.recovered(position)) {
      _recentLogs.add('[recover] 错误后播放继续推进，已解除错误态');
      _currentError = null;
      _errorController.add(null);
      _updateStatus(_pauseIntent ? PlaybackStatus.paused : PlaybackStatus.playing);
    }
  }

  void _publishDuration(Duration duration) {
    if (!_acceptMediaEvents) return;
    _duration = duration;
    _durationController.add(duration);
    _confirmOpenPosition();
  }

  void _confirmOpenPosition() {
    final hasMedia = _duration > Duration.zero ||
        (_awaitingPausedLiveOpen
            ? _hasOpenLiveFrame
            : _position > Duration.zero);
    if (!_awaitingOpenPosition || !_sawOpenPosition || !hasMedia) return;
    _awaitingOpenPosition = false;
    if (!_nativeBuffering && _status != PlaybackStatus.error) {
      _updateStatus(_pauseIntent ? PlaybackStatus.paused : PlaybackStatus.playing);
    }
  }

  /// 确认致命错误：直播先走断流重连，其余锁存为错误态（错误面板 / 自动换线据此工作）。
  void _commitError(String err) {
    if (_disposed || _externalPlaybackPaused || _hasPendingSeek) return;
    if (_scheduleLiveReconnect()) return;
    // 传输中断（清单/分段没读全）多为瞬时问题：同一地址先自动重开一次，再判失败。
    if (_shouldSoftRetry(err)) {
      _softRetrySpec = _currentSpec;
      _recentLogs.add('[retry] 传输中断，同一地址自动重开一次：$err');
      final spec = _currentSpec;
      if (spec != null) {
        final epoch = _sessionEpoch;
        unawaited(_open(spec).catchError((Object error) {
          if (!_isCurrentSession(epoch)) return;
          _currentError = '$error';
          _errorController.add(_currentError);
          _updateStatus(PlaybackStatus.error);
        }));
        return;
      }
    }
    _currentError = err;
    _errorController.add(err);
    _updateStatus(PlaybackStatus.error);
  }

  /// 是否值得「同一地址再开一次」：只针对传输中断，且每个会话只做一次。
  bool _shouldSoftRetry(String err) {
    final spec = _currentSpec;
    if (_disposed || _externalPlaybackPaused || spec == null) return false;
    if (identical(_softRetrySpec, spec)) return false;
    final text = err.toLowerCase();
    return text.contains('stream ends prematurely') || text.contains('ffurl_read');
  }

  void _cancelErrorConfirm() {
    _errorConfirmTimer?.cancel();
    _errorConfirmTimer = null;
    _errorGate.reset();
  }

  /// 直播会话断流时按退避策略安排重开；返回 false 表示非直播或重试已用尽。
  bool _scheduleLiveReconnect() {
    final spec = _currentSpec;
    if (_disposed || _externalPlaybackPaused || spec == null || !spec.isLive) {
      return false;
    }
    if (_reconnectTimer != null) return true;
    final delay = _liveReconnect.nextDelay();
    if (delay == null) return false;
    final epoch = _sessionEpoch;
    _recentLogs.add('[reconnect] 直播断流，${delay.inSeconds}s 后第 '
        '${_liveReconnect.attempts} 次重连');
    _updateStatus(PlaybackStatus.buffering);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || epoch != _sessionEpoch || _currentSpec != spec) return;
      unawaited(_open(spec).catchError((Object error) {
        if (epoch != _sessionEpoch) return;
        if (!_scheduleLiveReconnect()) {
          _currentError = '$error';
          _errorController.add(_currentError);
          _updateStatus(PlaybackStatus.error);
        }
      }));
    });
    return true;
  }

  void _cancelLiveReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _liveReconnect.reset();
  }

  /// 按会话类型写入网络缓冲参数（见 [sessionStreamProperties]）；须在 open 前生效。
  /// 把「系统代理」下发给 mpv。
  ///
  /// mpv/ffmpeg 只认进程环境变量（`HTTP_PROXY`/`HTTPS_PROXY`），读不到 Windows 的
  /// 「系统代理」设置（Clash 等的默认模式）。于是开着系统代理时：弹幕/伴随服务能联网，
  /// **播放器却在直连** —— HLS 子清单/分片走不通，表现就是时长只认出几秒、越播越长、
  /// 快到底再加载（§58 记录的同款症状，另一种成因）。
  ///
  /// 两条约束：① 回环地址（本机网盘代理）必须显式直连，否则会被塞进代理；
  /// ② 没有系统代理时**不动**，避免把用环境变量代理的用户清掉。
  Future<void> _applyPlaybackProxy(String url) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final host = Uri.tryParse(url)?.host ?? '';
    final loopback = host.isEmpty ||
        host == 'localhost' ||
        host == '::1' ||
        host.startsWith('127.');
    String value;
    if (loopback) {
      value = '';
    } else {
      final proxy = DanmakuApi.systemProxy();
      if (proxy == null || proxy.isEmpty) return;
      value = proxy.contains('://') ? proxy : 'http://$proxy';
    }
    try {
      await platform.setProperty('http-proxy', value);
    } catch (_) {
      // 个别 mpv 构建不支持该属性：保持默认，不影响主链路。
    }
  }

  Future<void> _applySessionStreamProperties(bool isLive, int epoch) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final entry in sessionStreamProperties(isLive: isLive).entries) {
      if (!_isCurrentSession(epoch)) return;
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {
        // 个别 mpv 构建不支持某属性：保持默认，不影响播放主链路。
      }
    }
  }

  void _resetMediaEvidence() {
    cancelSeekRecovery();
    _openingMedia = true;
    _awaitingOpenPosition = true;
    _sawOpenPosition = false;
    _hasOpenLiveFrame = false;
    _openedMediaUri = null;
    _nativeBuffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffer = Duration.zero;
    _dimensions = const VideoDimensions();
    _audioTracks = [];
    _subtitleTracks = [];
    _videoTracks = [];
    _positionController.add(_position);
    _durationController.add(_duration);
    _bufferController.add(_buffer);
    _dimensionsController.add(_dimensions);
    _audioTracksController.add(_audioTracks);
    _subtitleTracksController.add(_subtitleTracks);
    _videoTracksController.add(_videoTracks);
    _updateStatus(PlaybackStatus.buffering);
  }

  Future<void> _open(MediaPlaySpec spec,
      {bool play = true, int? sessionEpoch}) async {
    final epoch = sessionEpoch ?? _sessionEpoch;
    if (!_isCurrentSession(epoch) || _externalPlaybackPaused) return;
    final openEpoch = ++_openEpoch;
    _cancelErrorConfirm();
    _resetMediaEvidence();
    late final String openedUri;
    try {
      await _applySessionStreamProperties(spec.isLive, epoch);
      if (!_isCurrentSession(epoch) || openEpoch != _openEpoch) return;
      await _applyPlaybackProxy(spec.url);
      if (!_isCurrentSession(epoch) || openEpoch != _openEpoch) return;
      final media = Media(
        spec.url,
        // 站点没给 UA/Referer 时补浏览器默认值（有些源按 UA 拦非浏览器请求）。
        httpHeaders: withBrowserHeaderFallbacks(spec.headers, spec.url,
            enabled: playbackSettings.browserHeaders),
        // 直播是实时流，带起播位置会让 mpv 尝试 seek 到不存在的时间点。
        start: spec.isLive ? null : spec.startPosition,
      );
      openedUri = media.uri;
      _openedMediaUri = openedUri;
      await _player.open(media, play: play);
    } finally {
      if (_isCurrentSession(epoch) && openEpoch == _openEpoch) {
        // invariant: open's synthetic playing event is not loaded-media evidence.
        _openingMedia = false;
      }
    }
    await _readOpenedMediaEvidence(epoch, openEpoch, openedUri);
  }

  Future<void> _readOpenedMediaEvidence(
      int epoch, int openEpoch, String expectedUri) async {
    final platform = _player.platform;
    bool isCurrent() =>
        _isCurrentSession(epoch) &&
        openEpoch == _openEpoch &&
        _awaitingOpenPosition &&
        _acceptMediaEvents &&
        _openedMediaUri == expectedUri;
    if (platform is! NativePlayer || !isCurrent()) return;
    try {
      // Read mpv itself: Player.state can still describe the previous file.
      // Paused media may have emitted its only position while open was pending.
      final path = await platform.getProperty('path');
      if (!isCurrent() || path != expectedUri) return;
      if (await platform.getProperty('seeking') != 'no' || !isCurrent()) return;
      final duration = double.tryParse(await platform.getProperty('duration'));
      if (!isCurrent()) return;
      final position = double.tryParse(await platform.getProperty('time-pos'));
      if (!isCurrent()) return;
      final buffering = await platform.getProperty('paused-for-cache');
      if (!isCurrent() ||
          position == null ||
          !position.isFinite ||
          position < 0 ||
          buffering != 'no') {
        return;
      }
      final positiveDuration =
          duration != null && duration.isFinite && duration > 0 ? duration : null;
      VideoDimensions? decoded;
      if (positiveDuration == null) {
        if (!_awaitingPausedLiveOpen ||
            (duration != null && (!duration.isFinite || duration < 0))) {
          return;
        }
        if (await platform.getProperty('pause') != 'yes' || !isCurrent()) return;
        final width = int.tryParse(await platform.getProperty('video-dec-params/w'));
        if (!isCurrent()) return;
        final height = int.tryParse(await platform.getProperty('video-dec-params/h'));
        if (!isCurrent() || width == null || height == null || width <= 0 || height <= 0) {
          return;
        }
        if (await platform.getProperty('path') != expectedUri ||
            !isCurrent() || !_awaitingPausedLiveOpen) {
          return;
        }
        decoded = VideoDimensions(width: width, height: height);
      }
      _nativeBuffering = false;
      _publishDuration(positiveDuration == null
          ? Duration.zero
          : Duration(microseconds: (positiveDuration * Duration.microsecondsPerSecond).round()));
      if (decoded != null) {
        _hasOpenLiveFrame = true;
        _dimensions = decoded;
        _dimensionsController.add(decoded);
      }
      _publishPosition(Duration(
          microseconds: (position * Duration.microsecondsPerSecond).round()));
    } catch (error) {
      if (isCurrent()) _recentLogs.add('[source-evidence] $error');
    }
  }

  @override
  Future<void> play(MediaPlaySpec spec) async {
    if (_disposed) throw StateError('播放器已关闭');
    final epoch = ++_sessionEpoch;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    _pauseIntent = false;
    _externalPlaybackPaused = false;
    _currentSpec = spec;
    _softRetrySpec = null;
    _currentError = null;
    _errorController.add(null);
    _resetMediaEvidence();
    // 每次新播放会话重置诊断日志，避免上一部片的日志混进本次错误诊断。
    _recentLogs.clear();
    // 播放模式与来源 / 依据（探测结果、回退原因）写进诊断日志：
    // 「复制诊断」里能直接看到本次为什么按点播 / 直播起播。
    _recentLogs.add('[mode] ${spec.isLive ? '直播' : '点播'}'
        '（来源: ${playbackModeSourceLabel(spec.modeSource)}'
        '${spec.modeDetail == null ? '' : '；依据: ${spec.modeDetail}'}）');
    await _applySessionRate(spec);
    if (!_isCurrentSession(epoch)) return;
    await _open(spec, sessionEpoch: epoch);
  }

  /// Replaces media while keeping user playback controls and diagnostics.
  /// Completion only acknowledges open; callers must wait for fresh evidence.
  Future<void> switchSource(MediaPlaySpec spec) async {
    if (_disposed) throw StateError('播放器已关闭');
    final savedRate = _rate;
    final savedVolume = _volume;
    final wasPaused = _pauseIntent;
    final epoch = ++_sessionEpoch;
    _externalPlaybackPaused = false;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    _currentSpec = spec;
    _softRetrySpec = null;
    _currentError = null;
    _errorController.add(null);
    _resetMediaEvidence();
    _recentLogs.add('[source-switch] 保留倍速、音量和暂停状态');
    await _open(spec, play: !wasPaused, sessionEpoch: epoch);
    if (!_isCurrentSession(epoch)) return;
    await setRate(savedRate);
    if (!_isCurrentSession(epoch)) return;
    await setVolume(savedVolume);
    if (!_isCurrentSession(epoch)) return;
    if (_pauseIntent != wasPaused) {
      if (_pauseIntent) {
        await _player.pause();
      } else {
        await _player.play();
      }
    }
  }

  /// 验收 C1：「默认倍速」每次起播都生效（以前只在播放器初始化时应用一次，
  /// 改设置后重新起播仍是旧倍速；mpv 的 speed 跨文件保留，上一部片手动调的倍速也会带过来）。
  /// 直播固定 1x：实时流加速只会追到直播边缘后反复缓冲。
  Future<void> _applySessionRate(MediaPlaySpec spec) async {
    final target = sessionPlaybackRate(
        isLive: spec.isLive, defaultRate: playbackSettings.defaultRate);
    try {
      await setRate(target);
    } catch (_) {
      // 倍速写入失败不阻断起播。
    }
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _pauseIntent = true;
    await _player.pause();
    if (!_disposed) {
      await _readSettledSeekPosition();
      _readPendingLiveEvidence();
    }
  }

  /// Pauses a handed-off session without allowing background recovery to reopen
  /// it. The media and controls stay available for an explicit return to playback.
  Future<void> pauseForExternalPlayback() async {
    if (_disposed || _currentSpec == null) return;
    final epoch = ++_sessionEpoch;
    _openEpoch++;
    _externalPlaybackPaused = true;
    _pauseIntent = true;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    cancelSeekRecovery();
    // An invalidated open no longer owns its finally block. Retire its evidence
    // flags here, while the handoff gate keeps late native events from publishing.
    _openingMedia = false;
    _awaitingOpenPosition = false;
    _nativeBuffering = false;
    await _player.pause();
    if (!_isCurrentSession(epoch) || !_externalPlaybackPaused) return;
    _updateStatus(PlaybackStatus.paused);
  }

  @override
  Future<void> resume() async {
    if (_disposed) return;
    if (_externalPlaybackPaused) {
      // A pending handoff pause must not publish after an explicit resume.
      _sessionEpoch++;
      _externalPlaybackPaused = false;
    }
    _pauseIntent = false;
    await _player.play();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    final epoch = ++_sessionEpoch;
    _openEpoch++;
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    cancelSeekRecovery();
    _currentSpec = null;
    _pauseIntent = false;
    _externalPlaybackPaused = false;
    _openingMedia = false;
    _awaitingOpenPosition = false;
    await _player.stop();
    if (!_isCurrentSession(epoch)) return;
    _updateStatus(PlaybackStatus.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    // 直播兜底拒绝：即使将来 UI 新增了 seek 入口（画中画 / 遥控 / 脚本），
    // 也不把直播推进「seek → 流错误 → 断流重连 → 从头播」的坑。
    if (_currentSpec?.isLive == true) {
      _recentLogs.add(
          '[seek-rejected] 直播会话忽略 seek 到 ${position.inMilliseconds}ms');
      return;
    }
    await _seekTo(position, originalPosition: _position);
  }

  Future<void> _seekTo(Duration position,
      {required Duration originalPosition}) async {
    if (_disposed || _currentSpec == null || _openingMedia) return;
    final target = position < Duration.zero
        ? Duration.zero
        : _duration > Duration.zero && position > _duration
            ? _duration
            : position;
    final epoch = _sessionEpoch;
    _cancelErrorConfirm();
    _seekEvidenceGeneration = null;
    final generation = _seekRecovery.begin(
        originalPosition: originalPosition, targetPosition: target);
    try {
      await _player.seek(target);
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      _seekEvidenceGeneration = generation;
      await _readSettledSeekPosition();
    } catch (error) {
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      _recentLogs.add('[seek-command-error] $error');
      _seekRecovery.fail(generation);
    }
  }

  @override
  Future<void> retrySeek() async {
    final recovery = _seekRecovery.value;
    if (!recovery.isRecoverable) return;
    await _seekTo(recovery.targetPosition!,
        originalPosition: recovery.originalPosition!);
  }

  @override
  Future<void> returnToPreSeekPosition() async {
    final recovery = _seekRecovery.value;
    if (!recovery.isRecoverable) return;
    await _seekTo(recovery.originalPosition!,
        originalPosition: recovery.originalPosition!);
  }

  @override
  void cancelSeekRecovery() {
    _seekEvidenceGeneration = null;
    _seekRecovery.cancel();
  }

  Future<void> _observeNativeSeekCompletion() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty('seeking', (value) async {
        if (value == 'no') {
          await _readSettledSeekPosition();
          _readPendingLiveEvidence();
        }
      });
    } catch (error) {
      _recentLogs.add('[seek-observer] $error');
    }
  }

  Future<void> _readSettledSeekPosition() async {
    final generation = _seekEvidenceGeneration;
    if (generation == null || !_hasPendingSeek || !_acceptMediaEvents) return;
    final epoch = _sessionEpoch;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      if (await platform.getProperty('seeking') != 'no') return;
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      final seconds = double.tryParse(await platform.getProperty('time-pos'));
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation) {
        return;
      }
      final buffering = await platform.getProperty('paused-for-cache');
      if (!_isCurrentSession(epoch) ||
          _seekRecovery.value.generation != generation ||
          seconds == null ||
          !seconds.isFinite ||
          buffering != 'no') {
        return;
      }
      _seekRecovery.onPosition(
        Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()),
        generation: generation,
        isPaused: _pauseIntent,
        isBuffering: false,
      );
    } catch (error) {
      if (_isCurrentSession(epoch) &&
          _seekRecovery.value.generation == generation) {
        _recentLogs.add('[seek-evidence] $error');
      }
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 100.0);
    await _player.setVolume(clamped);
  }

  @override
  Future<void> setRate(double rate) async {
    final clamped = rate.clamp(0.25, 4.0);
    await _player.setRate(clamped);
  }

  @override
  Future<void> setHardwareDecoding(String mode) async {
    await applyPlaybackSettings(
        playbackSettings.copyWith(hwdec: PlayerSettings.normalizeHwdec(mode)));
  }

  @override
  Future<void> selectAudioTrack(TrackInfo track) async {
    final nativeAudio = _player.state.tracks.audio.firstWhere(
      (a) => a.id == track.id,
      orElse: () => AudioTrack(track.id, track.title, track.language),
    );
    await _player.setAudioTrack(nativeAudio);
  }

  @override
  Future<void> selectSubtitleTrack(TrackInfo track) async {
    final nativeSub = _player.state.tracks.subtitle.firstWhere(
      (s) => s.id == track.id,
      orElse: () => SubtitleTrack(track.id, track.title, track.language),
    );
    await _player.setSubtitleTrack(nativeSub);
  }

  @override
  Future<void> disableSubtitle() async {
    await _player.setSubtitleTrack(SubtitleTrack.no());
  }

  @override
  Future<void> selectVideoTrack(TrackInfo track) async {
    final VideoTrack native;
    if (track.id == 'auto') {
      native = VideoTrack.auto();
    } else if (track.id == 'no') {
      native = VideoTrack.no();
    } else {
      native = _player.state.tracks.video.firstWhere(
        (v) => v.id == track.id,
        orElse: () => VideoTrack(track.id, track.title, track.language),
      );
    }
    await _player.setVideoTrack(native);
  }

  void _updateStatus(PlaybackStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _statusController.add(newStatus);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sessionEpoch++;
    _openEpoch++;
    _seekEvidenceGeneration = null;
    _seekRecovery.dispose();
    _cancelLiveReconnect();
    _cancelErrorConfirm();
    await settingsApplication.dispose();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    if (_nativeCreated) await _player.dispose();
    await _statusController.close();
    await _positionController.close();
    await _durationController.close();
    await _bufferController.close();
    await _volumeController.close();
    await _rateController.close();
    await _dimensionsController.close();
    await _errorController.close();
    await _audioTracksController.close();
    await _subtitleTracksController.close();
    await _videoTracksController.close();
  }

  // --- 快照属性 ---
  @override
  PlaybackStatus get status => _status;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  Duration get buffer => _buffer;
  @override
  double get volume => _volume;
  @override
  double get rate => _rate;
  @override
  VideoDimensions get dimensions => _dimensions;
  @override
  String? get currentError => _currentError;
  @override
  MediaPlaySpec? get currentSpec => _currentSpec;

  /// 最近 40 条引擎日志（④ 诊断闭环；只读快照，供错误面板展示与复制）。
  List<String> get recentPlayerLogs => _recentLogs.entries;
  @override
  List<TrackInfo> get audioTracks => _audioTracks;
  @override
  List<TrackInfo> get subtitleTracks => _subtitleTracks;
  @override
  List<TrackInfo> get videoTracks => _videoTracks;

  // --- 状态流 ---
  @override
  Stream<PlaybackStatus> get statusStream => _statusController.stream;
  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration> get durationStream => _durationController.stream;
  @override
  Stream<Duration> get bufferStream => _bufferController.stream;
  @override
  Stream<double> get volumeStream => _volumeController.stream;
  @override
  Stream<double> get rateStream => _rateController.stream;
  @override
  Stream<VideoDimensions> get dimensionsStream => _dimensionsController.stream;
  @override
  Stream<String?> get errorStream => _errorController.stream;
  @override
  Stream<List<TrackInfo>> get audioTracksStream =>
      _audioTracksController.stream;
  @override
  Stream<List<TrackInfo>> get subtitleTracksStream =>
      _subtitleTracksController.stream;
  @override
  Stream<List<TrackInfo>> get videoTracksStream =>
      _videoTracksController.stream;
}
