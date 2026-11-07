/// 播放器运行状态枚举
enum PlaybackStatus {
  idle,
  buffering,
  playing,
  paused,
  completed,
  error,
}

/// 播放模式枚举（P0：直链 P0/P1 自动识别）
enum PlaybackMode { live, vod }

/// 播放模式来源（用于诊断与测试断言，不参与播放逻辑）
enum PlaybackModeSource {
  /// 默认：本地剧集等场景（点播）
  defaultMode,
  /// 直播入口未指定模式（导入频道 / 收藏 / 上次频道）——沿用旧行为按直播
  defaultLive,
  /// 直链弹窗（旧收藏 / 旧入口；不细分）
  directDialog,
  /// 容器扩展名判定（.mp4/.mkv 等）
  container,
  /// 清单探测判定
  probe,
  /// 用户手动选择
  manual,
  /// 主机记忆命中
  remembered,
  /// 播放器逃生口（本期未实现，预留）
  escapeHatch,
}

String playbackModeSourceLabel(PlaybackModeSource source) => switch (source) {
      PlaybackModeSource.defaultMode => '默认点播',
      PlaybackModeSource.defaultLive => '默认直播',
      PlaybackModeSource.directDialog => '直链弹窗',
      PlaybackModeSource.container => '容器扩展名',
      PlaybackModeSource.probe => '自动识别',
      PlaybackModeSource.manual => '手动选择',
      PlaybackModeSource.remembered => '主机记忆',
      PlaybackModeSource.escapeHatch => '播放器逃生口',
    };

/// 同一集的一档地址；[needsParse] 为真时必须先解析才能交给播放器。
class PlaybackQuality {
  final String name;
  final String url;
  final Map<String, String> headers;
  final bool needsParse;

  const PlaybackQuality({
    required this.name,
    required this.url,
    this.headers = const {},
    this.needsParse = false,
  });
}

class LiveDanmakuSource {
  const LiveDanmakuSource({required this.name, required this.url});

  final String name;
  final String url;
}

/// 媒体播放输入规约模型
class MediaPlaySpec {
  final String url;
  final Map<String, String>? headers;
  final String? title;
  /// 播放模式：单一事实来源（过渡期保留 `isLive:` 构造参数兼容既有调用点，不允许与 [mode] 同时提供且矛盾）
  final PlaybackMode mode;
  bool get isLive => mode == PlaybackMode.live;
  final PlaybackModeSource modeSource;
  final String? modeDetail;        // 回退原因/依据（不含敏感 header）；仅用于诊断
  final Duration? startPosition;

  /// 单档时为空；每档携带自己的请求头，不能复用当前档的解析器请求头。
  final List<PlaybackQuality> qualities;
  final int qualityIndex;
  final List<LiveDanmakuSource> liveDanmakuSources;

  const MediaPlaySpec({
    required this.url,
    this.headers,
    this.title,
    PlaybackMode? mode,
    bool? isLive,                   // 过渡期：与 [mode] 二选一
    this.modeSource = PlaybackModeSource.defaultMode,
    this.modeDetail,
    this.startPosition,
    this.qualities = const [],
    this.qualityIndex = 0,
    this.liveDanmakuSources = const [],
  }) : mode = mode ?? (isLive == true ? PlaybackMode.live : PlaybackMode.vod),
       assert(mode == null || isLive == null, 'mode 与 isLive 只能二选一');

  /// 点播会话（本地剧集 / 推送 / 网盘 / 直链点播）
  const MediaPlaySpec.vod({
    required this.url,
    this.headers,
    this.title,
    this.startPosition,
    this.modeSource = PlaybackModeSource.defaultMode,
    this.modeDetail,
    this.qualities = const [],
    this.qualityIndex = 0,
    this.liveDanmakuSources = const [],
  }) : mode = PlaybackMode.vod;

  /// 直播会话（导入频道 / 收藏 / 上次频道 / 直链按直播）
  const MediaPlaySpec.live({
    required this.url,
    this.headers,
    this.title,
    this.startPosition,
    this.modeSource = PlaybackModeSource.defaultLive,
    this.modeDetail,
    this.qualities = const [],
    this.qualityIndex = 0,
    this.liveDanmakuSources = const [],
  }) : mode = PlaybackMode.live;

  /// 未提供或为 null 的字段保持原值；空 headers/qualities 可清空对应集合。
  MediaPlaySpec copyWith({
    String? url,
    Map<String, String>? headers,
    String? title,
    PlaybackMode? mode,
    bool? isLive,
    PlaybackModeSource? modeSource,
    String? modeDetail,
    Duration? startPosition,
    List<PlaybackQuality>? qualities,
    int? qualityIndex,
    List<LiveDanmakuSource>? liveDanmakuSources,
  }) {
    assert(mode == null || isLive == null, 'mode 与 isLive 只能二选一');
    return MediaPlaySpec(
      url: url ?? this.url,
      headers: headers ?? this.headers,
      title: title ?? this.title,
      mode: mode ??
          (isLive == null
              ? this.mode
              : isLive ? PlaybackMode.live : PlaybackMode.vod),
      modeSource: modeSource ?? this.modeSource,
      modeDetail: modeDetail ?? this.modeDetail,
      startPosition: startPosition ?? this.startPosition,
      qualities: qualities ?? this.qualities,
      qualityIndex: qualityIndex ?? this.qualityIndex,
      liveDanmakuSources: liveDanmakuSources ?? this.liveDanmakuSources,
    );
  }

  @override
  String toString() => 'MediaPlaySpec(url: $url, title: $title, mode: ${mode.name}, isLive: $isLive, source: ${modeSource.name})';
}

/// 视频画面分辨率尺寸
class VideoDimensions {
  final int width;
  final int height;

  const VideoDimensions({this.width = 0, this.height = 0});

  double get aspectRatio => (width > 0 && height > 0) ? width / height : 16 / 9;

  @override
  String toString() => '${width}x$height';
}
