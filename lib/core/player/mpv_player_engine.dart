import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'models/player_settings.dart';
import 'models/player_state.dart';
import 'models/track_info.dart';
import 'playback_diagnostics.dart';
import 'player_engine.dart';
import 'player_track_capabilities.dart';
import 'player_settings_application.dart';
import 'mpv_settings_target.dart';

/// 基于 media_kit (libmpv) 的 Windows 平台硬件加速播放引擎实现
class MpvPlayerEngine
    implements PlayerEngine, VideoTrackCapable, SubtitleTrackCapable {
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

  final settingsApplication = PlayerSettingsApplication();
  Future<void>? _initialization;
  bool _nativeCreated = false;
  bool _disposed = false;

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
      _player = Player(
        configuration: const PlayerConfiguration(
          pitch: true,
          // ⑥ 内存批：播放缓冲 32MB -> 16MB（1080p 约 6~10 秒余量，视码率），
          // 换取播放期峰值内存下降；起播/流畅度在 V2 采样与实机验收中复核。
          bufferSize: 16 * 1024 * 1024,
          logLevel: MPVLogLevel.warn,
        ),
      );
      _nativeCreated = true;
      _videoController = VideoController(_player);
      _bindNativeStreams();
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

  @override
  Future<void> applyPlaybackSettings(PlayerSettings settings) =>
      settingsApplication.update(settings);

  void _bindNativeStreams() {
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (_status != PlaybackStatus.error) {
          _updateStatus(
              playing ? PlaybackStatus.playing : PlaybackStatus.paused);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (buffering && _status != PlaybackStatus.error) {
          _updateStatus(PlaybackStatus.buffering);
        } else if (!buffering && _status == PlaybackStatus.buffering) {
          _updateStatus(_player.state.playing
              ? PlaybackStatus.playing
              : PlaybackStatus.paused);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed) {
          _updateStatus(PlaybackStatus.completed);
        }
      }),
    );

    _subscriptions.add(
      _player.stream.position.listen((pos) {
        _position = pos;
        _positionController.add(pos);
      }),
    );

    _subscriptions.add(
      _player.stream.duration.listen((dur) {
        _duration = dur;
        _durationController.add(dur);
      }),
    );

    _subscriptions.add(
      _player.stream.buffer.listen((buf) {
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
        _dimensions =
            VideoDimensions(width: w ?? 0, height: _player.state.height ?? 0);
        _dimensionsController.add(_dimensions);
      }),
    );

    _subscriptions.add(
      _player.stream.height.listen((h) {
        _dimensions =
            VideoDimensions(width: _player.state.width ?? 0, height: h ?? 0);
        _dimensionsController.add(_dimensions);
      }),
    );

    _subscriptions.add(
      _player.stream.tracks.listen((tracks) {
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
        if (err.isNotEmpty) {
          _currentError = err;
          _errorController.add(err);
          _updateStatus(PlaybackStatus.error);
        }
      }),
    );
  }

  @override
  Future<void> play(MediaPlaySpec spec) async {
    _currentSpec = spec;
    _currentError = null;
    _errorController.add(null);
    // 每次新播放会话重置诊断日志，避免上一部片的日志混进本次错误诊断。
    _recentLogs.clear();
    _updateStatus(PlaybackStatus.buffering);

    final media = Media(
      spec.url,
      httpHeaders: spec.headers,
      start: spec.startPosition,
    );

    await _player.open(media, play: true);
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> resume() async {
    await _player.play();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _currentSpec = null;
    _updateStatus(PlaybackStatus.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
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
