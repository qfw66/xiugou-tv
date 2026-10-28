import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/danmaku/danmaku_controller.dart';
import '../../../core/danmaku/danmaku_settings.dart';
import '../../../core/player/models/player_settings.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/player/models/track_info.dart';
import '../../../core/player/mpv_player_engine.dart';
import '../../../core/player/playback_intent.dart';
import '../../../core/segments/segment_models.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../keyboard/player_shortcuts.dart';
import 'danmaku_layer.dart';
import 'danmaku_settings_panel.dart';
import 'episode_drawer.dart';
import 'playback_preparing_overlay.dart';
import '../widgets/focus_ring.dart';
import '../window/desktop_window_manager.dart';
import 'live_channel_drawer.dart';
import 'playback_error_panel.dart';
import 'player_osd_overlay.dart';
import 'player_side_drawer.dart';
import 'segment_panel.dart';
import 'segment_runner.dart';

// ---- 播放器控制层（顶部 / 底部）恒定深色 chrome ----
//
// 控制层遮罩与前景与主题解耦（视频播放器惯例：控制层恒深、前景恒浅）。
// 浅色主题下若沿用主题色，会出现「白色渐变盖住画面 + 深色文字压深底」的
// 错位观感（用户实机反馈）。固定值取深色主题的对应色。
// 刻意固定色：调整前先确认控制层遮罩仍为深色。
const Color _chromeScrim = Color(0xCC000000); // 顶 / 底遮罩主色
const Color _chromeScrimFade = Color(0x00000000); // 遮罩渐隐端
const Color _chromeInk = Color(0xFFFFFFFF); // 控制层前景（文字 / 图标 / 滑条）
const Color _chromeHighlight = Color(0xFF94A3B8); // 高亮（已设态 / 已播进度）
const Color _chromeTrack = Color(0xFF2E2E3C); // 滑条未播 / 未满轨道
const Color _chromeBadge = Color(0xFF414A5B); // 徽章底（HW 标识）

/// 画面缩放模式 → 视频纹理适配方式（比例强制由 mpv `video-aspect-override` 负责）。
BoxFit videoFitForScale(String scale) => switch (scale) {
      'fill' => BoxFit.fill,
      'crop' => BoxFit.cover,
      _ => BoxFit.contain,
    };

/// §43 弹幕视图模型（由宿主装配：加载 / 缓存 / 取消都在宿主的 [DanmakuController]）。
class PlayerDanmakuNav {
  const PlayerDanmakuNav({
    required this.state,
    required this.enabled,
    required this.onToggle,
    this.settings = DanmakuSettings.defaults,
    this.onSettingsChanged,
  });

  /// 播放页「弹幕设置」抽屉里改了设置（宿主负责落盘）；为 null 时不显示该入口。
  final ValueChanged<DanmakuSettings>? onSettingsChanged;

  /// 外观与屏蔽（设置页「弹幕」分组，实时生效）
  final DanmakuSettings settings;

  /// 加载状态（含已解析的弹幕轨）
  final ValueListenable<DanmakuState> state;

  /// 当前播放是否显示弹幕
  final bool enabled;

  /// 「弹」按钮 / D 键
  final VoidCallback onToggle;
}

/// 播放器内切集视图模型（由宿主装配；组件保持哑视图，切换逻辑不在组件内）。
class PlayerEpisodeNav {
  /// 是否可切到上一集（首集为 false → 按钮禁用）。
  final bool canPrev;

  /// 是否可切到下一集（末集为 false → 按钮禁用）。
  final bool canNext;

  /// 切换进行中：两个按钮一并禁用，防重复触发。
  final bool switching;

  final VoidCallback onPrevEpisode;
  final VoidCallback onNextEpisode;

  const PlayerEpisodeNav({
    required this.canPrev,
    required this.canNext,
    this.switching = false,
    required this.onPrevEpisode,
    required this.onNextEpisode,
  });
}

/// 播放器内刷新视图模型（由宿主装配；组件保持哑视图，刷新逻辑不在组件内）。
class PlayerRefreshNav {
  /// 刷新进行中：按钮禁用并吸收点击。
  final bool busy;

  final VoidCallback onRefresh;

  const PlayerRefreshNav({required this.busy, required this.onRefresh});
}

/// 播放器内片头 / 片尾视图模型（由宿主装配；0 表示未设置）。
///
/// 写入语义：`onSetOpeningAt` / `onSetEndingAt` 接收**绝对时间点**（毫秒），
/// 片尾的「距片尾偏移」换算、范围与重叠校验、持久化都在宿主完成；
/// 组件只负责触发，不落任何盘。
class PlayerSkipNav {
  final int openingMs;
  final int endingMs;

  /// 片头片尾总开关；关闭时「跳过片头」胶囊不应出现。
  final bool enabled;

  /// 设为片头 / 片尾（参数为绝对时间点毫秒）。
  final ValueChanged<int> onSetOpeningAt;
  final ValueChanged<int> onSetEndingAt;

  /// 清除片头 / 片尾标记。
  final VoidCallback onClearOpening;
  final VoidCallback onClearEnding;

  const PlayerSkipNav({
    this.openingMs = 0,
    this.endingMs = 0,
    this.enabled = true,
    required this.onSetOpeningAt,
    required this.onSetEndingAt,
    required this.onClearOpening,
    required this.onClearEnding,
  });
}

/// 播放器内重播视图模型（由宿主装配；为空时隐藏重播按钮）。
class PlayerReplayNav {
  /// 切换 / 刷新进行中：重播禁用，避免与启动链路竞争。
  final bool busy;
  final VoidCallback onReplay;

  const PlayerReplayNav({required this.busy, required this.onReplay});
}

/// 播放器内视频轨视图模型（由宿主装配；为空时不显示「视轨」）。
///
/// 通过可选能力接口从真实引擎装配，测试替身不提供该视图模型即自动隐藏入口。
class PlayerVideoTracksNav {
  final List<TrackInfo> tracks;
  final Stream<List<TrackInfo>> tracksStream;
  final Future<void> Function(TrackInfo track) onSelect;

  /// 当前是否处于「关闭视频」状态（mpv `vid=no`）。
  final bool isDisabled;

  const PlayerVideoTracksNav({
    required this.tracks,
    required this.tracksStream,
    required this.onSelect,
    this.isDisabled = false,
  });
}

/// 播放器内音轨视图模型（由宿主装配；为空时不显示「音轨」）。
class PlayerAudioTracksNav {
  final List<TrackInfo> tracks;
  final Stream<List<TrackInfo>> tracksStream;
  final Future<void> Function(TrackInfo track) onSelect;

  const PlayerAudioTracksNav({
    required this.tracks,
    required this.tracksStream,
    required this.onSelect,
  });
}

/// 播放器内字幕视图模型（由宿主装配；为空时不显示「字幕」）。
class PlayerSubtitleTracksNav {
  final List<TrackInfo> tracks;
  final Stream<List<TrackInfo>> tracksStream;
  final Future<void> Function(TrackInfo track) onSelect;

  /// 关闭字幕；为空时不显示「关闭字幕」项。
  final Future<void> Function()? onDisable;

  const PlayerSubtitleTracksNav({
    required this.tracks,
    required this.tracksStream,
    required this.onSelect,
    this.onDisable,
  });
}

/// 播放器内重置视图模型（由宿主装配；为空时不显示「重置」）。
class PlayerResetNav {
  /// 切换 / 刷新进行中：重置禁用，避免与启动链路竞争。
  final bool enabled;
  final Future<void> Function() onReset;

  const PlayerResetNav({this.enabled = true, required this.onReset});
}

/// 播放器内「线路」分组里的一条线路。
class PlayerLineOption {
  /// `session.sources` 的下标（选项可能因缺集而跳号，不能用列表位置代替）。
  final int index;
  final String name;

  /// 当前正在播放的线路（显示勾选、不可点）。
  final bool current;

  /// 本次会话里已尝试并失败的线路（灰显、不可点）。
  /// 确认失败（解析为空 / 启动抛错）；只是「用过」不算。
  final bool unavailable;

  const PlayerLineOption({
    required this.index,
    required this.name,
    this.current = false,
    this.unavailable = false,
  });
}

/// 播放器内线路视图模型（SET-12 重做；由宿主装配，组件保持哑视图）。
///
/// 只有一条线路时宿主应传 null，面板不显示「线路」分组。
class PlayerLineNav {
  final List<PlayerLineOption> options;

  /// 换线 / 刷新 / 切集进行中：全部线路不可点。
  final bool busy;

  /// `index` 是 `session.sources` 的下标（不是 options 的下标）。
  final void Function(int index) onSelect;

  const PlayerLineNav({
    required this.options,
    required this.busy,
    required this.onSelect,
  });
}

/// 从真实 mpv 引擎装配三个轨道视图模型（宿主使用；测试可用假引擎直接验证接线）。
({
  PlayerAudioTracksNav audio,
  PlayerSubtitleTracksNav subtitle,
  PlayerVideoTracksNav video,
}) buildPlayerTrackNavs(MpvPlayerEngine engine) => (
      audio: PlayerAudioTracksNav(
        tracks: engine.audioTracks,
        tracksStream: engine.audioTracksStream,
        onSelect: engine.selectAudioTrack,
      ),
      subtitle: PlayerSubtitleTracksNav(
        tracks: engine.subtitleTracks,
        tracksStream: engine.subtitleTracksStream,
        onSelect: engine.selectSubtitleTrack,
        onDisable: engine.disableSubtitle,
      ),
      video: PlayerVideoTracksNav(
        tracks: engine.videoTracks,
        tracksStream: engine.videoTracksStream,
        onSelect: engine.selectVideoTrack,
        isDisabled: engine.isVideoDisabled,
      ),
    );

/// Windows 桌面端高清视频渲染与交互控制播放器组件
class DesktopVideoPlayer extends StatefulWidget {
  final MpvPlayerEngine playerEngine;
  final DesktopWindowManager windowManager;

  /// 画面缩放模式（`PlayerSettings.scale`）：决定视频纹理在窗口中的适配方式
  final String scale;
  final VoidCallback? onBack;

  /// 可替换平台视频表面，控制栏与播放状态仍使用同一条真实渲染链路。
  /// 未提供时使用 MPV 视频纹理。
  final Widget? videoSurface;

  /// 播放内切集视图模型；为空时不显示「上一集 / 下一集」（直播 / 推送 / 单集）。
  final PlayerEpisodeNav? episodeNav;

  /// 右侧「选集 + 线路」抽屉（§20）；为空时不显示入口（直播 / 推送 / 单集）。
  final PlayerEpisodeListNav? episodeListNav;

  /// 播放内刷新视图模型；为空时不显示「刷新」。
  final PlayerRefreshNav? refreshNav;

  /// 播放内片头 / 片尾视图模型；为空时不显示这两个入口（直播 / 推送 / 续播）。
  final PlayerSkipNav? skipNav;

  /// 播放内重播视图模型；为空时不显示「重播」。
  final PlayerReplayNav? replayNav;

  /// 当前播放引擎信息（如「MPV 播放器」）；为空时不显示。
  final String? playerInfoLabel;

  /// 画面比例选择回调（复用 `PlayerSettings.scaleOptions`）；为空时不显示比例入口。
  final Future<void> Function(String scale)? onScaleChanged;

  /// 视频轨视图模型；为空时不显示「视轨」。
  final PlayerVideoTracksNav? videoTracksNav;

  /// 音轨视图模型；为空时不显示「音轨」。
  final PlayerAudioTracksNav? audioTracksNav;

  /// 字幕视图模型；为空时不显示「字幕」。
  final PlayerSubtitleTracksNav? subtitleTracksNav;

  /// 重置视图模型；为空时不显示「重置」。
  final PlayerResetNav? resetNav;

  /// 线路视图模型；为空或只有一条线路时不显示「线路」分组。
  final PlayerLineNav? lineNav;

  /// ⑤-3 直播切台快捷键（← / →）：仅直播时由宿主传入；为空时保持快退 / 快进。
  final VoidCallback? onLivePrev;
  final VoidCallback? onLiveNext;

  /// ⑤-3 修复：直播频道抽屉数据。非空时在「视频表面层」挂
  /// [LiveChannelLayer]（控制条之下）——返回 / 播放 / 时间轴不被遮挡。
  final List<Live>? liveChannels;

  /// 当前频道在 [liveChannels] 中的下标（抽屉高亮 / 滚动定位）。
  final int liveCurrentIndex;

  /// 已收藏频道的键集合（§34）：抽屉顶部置顶「收藏频道」小节用它过滤。
  final Set<String> liveFavoriteKeys;

  /// 抽屉选台回调；[liveChannels] 为空时不会触发。
  final ValueChanged<int>? onLiveSelect;

  /// 抽屉「管理频道」入口回调。
  final VoidCallback? onLiveManage;

  /// 播放页激活时是否隐藏窗口自绘标题栏（§38 沉浸播放）。
  ///
  /// 组件只把状态同步给窗口层（`DesktopWindowManager.setImmersive`），
  /// 标题栏的浮出 / 收回由窗口框架负责；`false` 时回到传统布局。
  final bool hideWindowTitleBar;

  /// 起播准备态（§16）：非空时在画面上盖一层骨架/失败面板。
  ///
  /// 解析播放地址在弱网下要几秒；把播放页先亮出来、状态放页内，
  /// 用户点完立刻有反馈，且失败可原地重试。
  final PlaybackIntent? preparing;

  /// 准备失败时的「重试」回调。
  final VoidCallback? onRetryPrepare;

  /// 准备态的「返回」回调（退出准备态回到列表）。
  final VoidCallback? onCancelPrepare;

  /// 起播后检测到「正在播放但音量为 0」时回调一次（§36）。
  ///
  /// 用来提醒用户「不是没声音，是被静音了」。同一播放器实例只触发一次。
  final VoidCallback? onMutedPlaybackDetected;

  /// 用户把音量调到某个值（含静音 / 取消静音）后回调（§36）。
  ///
  /// 播放器只负责 UI 与 OSD；「记住这个音量」由宿主决定怎么落盘，
  /// 这样窗口层不用认识 SettingsRepository。
  final ValueChanged<double>? onVolumeCommitted;

  /// §43 弹幕；为空时不显示弹幕层与按钮（直播 / 推送）。
  final PlayerDanmakuNav? danmakuNav;

  /// §44 共享片段；为空时不显示「片段」按钮与执行器（未配置服务 / 直播 / 推送）。
  final PlayerSegmentsNav? segmentsNav;
  const DesktopVideoPlayer({
    super.key,
    required this.playerEngine,
    required this.windowManager,
    this.hideWindowTitleBar = true,
    this.scale = 'fit',
    this.onBack,
    this.videoSurface,
    this.episodeNav,
    this.episodeListNav,
    this.refreshNav,
    this.skipNav,
    this.replayNav,
    this.playerInfoLabel,
    this.onScaleChanged,
    this.videoTracksNav,
    this.audioTracksNav,
    this.subtitleTracksNav,
    this.resetNav,
    this.lineNav,
    this.onLivePrev,
    this.onLiveNext,
    this.liveChannels,
    this.liveCurrentIndex = 0,
    this.liveFavoriteKeys = const {},
    this.onLiveSelect,
    this.onLiveManage,
    this.preparing,
    this.onRetryPrepare,
    this.onCancelPrepare,
    this.onVolumeCommitted,
    this.onMutedPlaybackDetected,
    this.danmakuNav,
    this.segmentsNav,
  });

  @override
  State<DesktopVideoPlayer> createState() => _DesktopVideoPlayerState();
}

class _DesktopVideoPlayerState extends State<DesktopVideoPlayer> {
  final FocusNode _focusNode = FocusNode();
  final OsdController _osdController = OsdController();

  bool _showControls = true;
  Timer? _hideControlsTimer;
  static const Duration _hideDelay = Duration(seconds: 3);

  /// §37：指针是否停在顶 / 底控制条热区内。
  ///
  /// 显隐判定从「鼠标在动」改成「指针在热区」—— 画面中部移动不再唤起控制条，
  /// 离开热区 [_chromeExitDelay] 后收起（比 3 秒的键盘兜底快，才符合「移走就隐藏」）。
  bool _pointerInChrome = false;

  /// §44 指针停在右下角片段 / 跳过片头胶囊上（视作控制区：不隐藏控制条）
  bool _pointerOnPill = false;
  static const double _topChromeZone = 62;
  static const double _bottomChromeZone = 110;
  static const Duration _chromeExitDelay = Duration(milliseconds: 150);

  /// 沉浸播放（§38）：窗口自绘标题栏此时不渲染，窗口三键并进本顶栏。
  bool _immersive = false;

  /// §20 选集抽屉（右侧）：打开期间不自动隐藏控制条，Esc / 点遮罩关闭。
  bool _episodeDrawerOpen = false;

  /// 底栏隐藏时下移的距离：必须大于底栏实际高度（约 106px）。
  /// 取 -80 时屏幕底部会残留一条（残留的正好是进度条行，见 backlog §12 #6）。
  static const double _bottomBarHideOffset = -160;

  /// 底栏焦点跟踪：键盘焦点落在控制条内时暂停自动隐藏，
  /// 避免焦点控件被滑出屏幕（WCAG 2.2 focus-not-obscured）。
  final FocusNode _bottomBarFocusNode = FocusNode(
      debugLabel: 'PlayerBottomBar',
      skipTraversal: true,
      canRequestFocus: false);
  bool _bottomBarHasFocus = false;

  double _dragSeekPositionMs = -1.0;
  double _lastUnmutedVolume = 100.0;

  /// 进度条悬停态（B5：悬停加粗，200ms 过渡）。
  bool _progressHovered = false;

  /// 视轨菜单最近一次成功选择（`auto` / `no` / `video:<id>`），用于关闭态勾选。
  String? _videoSelectionOverride;

  /// 静音提醒只弹一次（同一播放器实例内）。
  bool _mutedHintSent = false;

  /// 静音起播检测用的引擎状态订阅（dispose 时取消）。
  StreamSubscription<PlaybackStatus>? _statusSubscription;

  Future<void> _checkMutedPlayback() async {
    if (_mutedHintSent) return;
    final status = widget.playerEngine.status;
    if (status != PlaybackStatus.playing) return;
    if (widget.playerEngine.volume > 0) return;
    _mutedHintSent = true;
    widget.onMutedPlaybackDetected?.call();
  }

  @override
  void initState() {
    super.initState();
    widget.windowManager.isPipNotifier.addListener(_onPipChanged);
    widget.windowManager.isImmersiveNotifier.addListener(_onImmersiveChanged);
    _immersive = widget.windowManager.isImmersiveNotifier.value;
    _syncImmersive(widget.hideWindowTitleBar);
    _bottomBarFocusNode.addListener(_onBottomBarFocusChanged);
    // 引擎是全应用单例（广播流）：订阅必须在 dispose 时取消，否则每进一次播放页
    // 就多挂一个监听，闭包还会拽住整个 State 无法回收（2026-10-28 发布前资源审查）。
    _statusSubscription = widget.playerEngine.statusStream.listen((status) {
      if (status == PlaybackStatus.playing) _checkMutedPlayback();
    });
    _startHideTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant DesktopVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoTracksNav != widget.videoTracksNav) {
      _videoSelectionOverride = null;
    }
    if (oldWidget.hideWindowTitleBar != widget.hideWindowTitleBar) {
      _syncImmersive(widget.hideWindowTitleBar);
    }
    // 会话关闭 / 切成直播：抽屉没有内容可列，直接收起（避免空面板挂屏）。
    if (widget.episodeListNav == null && _episodeDrawerOpen) {
      _episodeDrawerOpen = false;
    }
  }

  @override
  void dispose() {
    unawaited(_statusSubscription?.cancel());
    _hideControlsTimer?.cancel();
    _syncImmersive(false);
    widget.windowManager.isPipNotifier.removeListener(_onPipChanged);
    widget.windowManager.isImmersiveNotifier
        .removeListener(_onImmersiveChanged);
    _bottomBarFocusNode.removeListener(_onBottomBarFocusChanged);
    _bottomBarFocusNode.dispose();
    _focusNode.dispose();
    _osdController.dispose();
    super.dispose();
  }

  void _onUserActivity() {
    // 从设置中心等覆盖层返回后焦点不会自动回到播放器，用户一有操作即收回快捷键焦点
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    _startHideTimer();
  }

  void _startHideTimer() => _scheduleHide(_hideDelay);

  void _scheduleHide(Duration delay) {
    _hideControlsTimer?.cancel();
    // 焦点在控制条内时不自动隐藏（WCAG 2.2 focus-not-obscured）；
    // §37：指针停在热区里时也不隐藏（「放上去就显示」）。
    if (_bottomBarHasFocus || _episodeDrawerOpen || _pointerInChrome) return;
    if (widget.playerEngine.status == PlaybackStatus.playing) {
      _hideControlsTimer = Timer(delay, () {
        if (mounted &&
            widget.playerEngine.status == PlaybackStatus.playing &&
            !_pointerInChrome) {
          setState(() => _showControls = false);
        }
      });
    }
  }

  /// §37：指针位置决定显隐 —— 只认顶 / 底热区，画面中部移动不再唤起。
  void _onChromeHover(Offset localPosition) {
    // PiP 小窗保留旧口径：窗口只有 400×225，热区化会让整窗都是热区。
    if (widget.windowManager.isPipNotifier.value) {
      _onUserActivity();
      return;
    }
    final size = context.size;
    if (size == null) return;
    final inZone = _pointerOnPill ||
        localPosition.dy <= _topChromeZone ||
        localPosition.dy >= size.height - _bottomChromeZone;
    if (inZone) {
      _pointerInChrome = true;
      _hideControlsTimer?.cancel();
      if (!_showControls) setState(() => _showControls = true);
      return;
    }
    _pointerInChrome = false;
    // 已经排期过就不再反复重置（悬停事件非常密集）。
    if (_showControls && _hideControlsTimer?.isActive != true) {
      _scheduleHide(_chromeExitDelay);
    }
  }

  /// 指针离开播放器（例如移到窗口标题栏）时按「移走就隐藏」处理。
  void _onChromeExit() {
    if (widget.windowManager.isPipNotifier.value) return;
    _pointerInChrome = false;
    if (_showControls) _scheduleHide(_chromeExitDelay);
  }

  /// 把「沉浸播放」开关同步给窗口层。
  ///
  /// 必须挪出 build 相位：窗口框架用 `ValueListenableBuilder` 监听它，
  /// 在 initState / didUpdateWidget 里直接改通知器会触发
  /// 「setState() called during build」。微任务在当帧回调结束后执行，既安全又不闪。
  void _syncImmersive(bool value) {
    final manager = widget.windowManager;
    scheduleMicrotask(() {
      if (value && !mounted) return;
      manager.setImmersive(value);
    });
  }

  void _onImmersiveChanged() {
    final immersive = widget.windowManager.isImmersiveNotifier.value;
    if (immersive == _immersive) return;
    if (mounted) setState(() => _immersive = immersive);
  }

  void _onBottomBarFocusChanged() {
    final hasFocus = _bottomBarFocusNode.hasFocus;
    if (hasFocus == _bottomBarHasFocus) return;
    _hideControlsTimer?.cancel();
    setState(() {
      _bottomBarHasFocus = hasFocus;
      // 焦点进入时确保控制条可见（含 Tab 进入已隐藏控制条的场景）；
      // 焦点离开后由 _startHideTimer 恢复倒计时。
      if (hasFocus) _showControls = true;
    });
    if (!hasFocus) _startHideTimer();
  }

  /// §20：工具栏按钮开关右侧选集抽屉。
  void _toggleEpisodeDrawer() {
    if (widget.episodeListNav == null) return;
    if (_episodeDrawerOpen) {
      _closeEpisodeDrawer();
      return;
    }
    _hideControlsTimer?.cancel();
    setState(() {
      _showControls = true;
      _episodeDrawerOpen = true;
    });
  }

  void _closeEpisodeDrawer() {
    if (!_episodeDrawerOpen) return;
    setState(() => _episodeDrawerOpen = false);
    _startHideTimer();
  }

  void _togglePlayPause() {
    final isPlaying = widget.playerEngine.status == PlaybackStatus.playing;
    if (isPlaying) {
      widget.playerEngine.pause();
      _osdController.show(Icons.pause_rounded, '已暂停');
    } else {
      widget.playerEngine.resume();
      _osdController.show(Icons.play_arrow_rounded, '播放中');
    }
    _onUserActivity();
  }

  void _handleSeek(Duration delta) {
    final curPos = widget.playerEngine.position;
    final dur = widget.playerEngine.duration;
    final targetMs = (curPos.inMilliseconds + delta.inMilliseconds)
        .clamp(0, dur.inMilliseconds);
    final targetDuration = Duration(milliseconds: targetMs);
    widget.playerEngine.seek(targetDuration);

    final isForward = delta > Duration.zero;
    _osdController.show(
      isForward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
      '${isForward ? '+' : ''}${delta.inSeconds}s',
      subText: '${_formatDuration(targetDuration)} / ${_formatDuration(dur)}',
    );
    _onUserActivity();
  }

  void _handleVolumeAdjust(double delta) {
    final currentVol = widget.playerEngine.volume;
    final targetVol = (currentVol + delta).clamp(0.0, 100.0);
    widget.playerEngine.setVolume(targetVol);
    if (targetVol > 0) _lastUnmutedVolume = targetVol;

    _osdController.show(
      targetVol == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      '音量: ${targetVol.toInt()}%',
    );
    _commitVolume(targetVol);
    _onUserActivity();
  }

  /// 把最新音量交给宿主记住（§36）。静音时上报 0 —— 宿主会跳过 0，
  /// 避免「静音一次，下次进来默认音量也变成 0」。
  void _commitVolume(double value) {
    widget.onVolumeCommitted?.call(value);
  }

  void _handleToggleMute() {
    final currentVol = widget.playerEngine.volume;
    if (currentVol > 0) {
      _lastUnmutedVolume = currentVol;
      widget.playerEngine.setVolume(0.0);
      _osdController.show(Icons.volume_off_rounded, '已静音');
      _commitVolume(0);
    } else {
      final restoreVol = _lastUnmutedVolume > 0 ? _lastUnmutedVolume : 100.0;
      widget.playerEngine.setVolume(restoreVol);
      _osdController.show(
          Icons.volume_up_rounded, '音量: ${restoreVol.toInt()}%');
      _commitVolume(restoreVol);
    }
    _onUserActivity();
  }

  void _handleRateAdjust(double delta, {bool reset = false}) {
    final currentRate = widget.playerEngine.rate;
    final targetRate = reset ? 1.0 : (currentRate + delta).clamp(0.25, 3.0);
    widget.playerEngine.setRate(targetRate);

    _osdController.show(Icons.speed_rounded, '倍速: ${targetRate}x');
    _onUserActivity();
  }

  void _handlePrevEpisode() {
    final nav = widget.episodeNav;
    if (nav == null || nav.switching || !nav.canPrev) return;
    _osdController.show(Icons.skip_previous_rounded, '上一集');
    nav.onPrevEpisode();
    _onUserActivity();
  }

  void _handleNextEpisode() {
    final nav = widget.episodeNav;
    if (nav == null || nav.switching || !nav.canNext) return;
    _osdController.show(Icons.skip_next_rounded, '下一集');
    nav.onNextEpisode();
    _onUserActivity();
  }

  void _handleRefresh() {
    final nav = widget.refreshNav;
    if (nav == null || nav.busy) return;
    _osdController.show(Icons.refresh_rounded, '刷新中…');
    nav.onRefresh();
    _onUserActivity();
  }

  void _handleOpeningSkip() {
    final nav = widget.skipNav;
    if (nav == null) return;
    nav.onSetOpeningAt(widget.playerEngine.position.inMilliseconds);
    _onUserActivity();
  }

  void _handleEndingSkip() {
    final nav = widget.skipNav;
    if (nav == null) return;
    nav.onSetEndingAt(widget.playerEngine.position.inMilliseconds);
    _onUserActivity();
  }

  void _handleClearOpeningSkip() {
    final nav = widget.skipNav;
    if (nav == null) return;
    nav.onClearOpening();
    _onUserActivity();
  }

  void _handleClearEndingSkip() {
    final nav = widget.skipNav;
    if (nav == null) return;
    nav.onClearEnding();
    _onUserActivity();
  }

  /// 表面层滚轮：仅右半屏调音量（±5，与键盘 ↑↓ 同一步长；左半屏无操作）。
  void _handleSurfacePointerSignal(PointerSignalEvent event, double width) {
    if (event is! PointerScrollEvent) return;
    if (event.localPosition.dx < width / 2) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    _handleVolumeAdjust(dy < 0 ? 5.0 : -5.0);
  }

  /// 时间轴右键菜单：在点击处设置片头 / 片尾，或清除已设标记。
  Future<void> _showTimelineMenu(TapUpDetails details, double width) async {
    final nav = widget.skipNav;
    if (nav == null) return;
    final durMs = widget.playerEngine.duration.inMilliseconds;
    final blocked = durMs <= 0;
    // 滑条两端让出 overlay 半径（24px）后线性映射；中点 ≈ 时长一半。
    const inset = 24.0;
    final track = (width - inset * 2).clamp(1.0, double.infinity);
    final fraction =
        ((details.localPosition.dx - inset) / track).clamp(0.0, 1.0);
    final clickedMs = (fraction * durMs).round();
    final at = _formatDuration(Duration(milliseconds: clickedMs));
    final choice = await showMenu<int>(
      context: context,
      color: context.palette.raised,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md)),
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: [
        PopupMenuItem<int>(
          value: 0,
          enabled: !blocked,
          height: 40,
          child: _menuIconRow(Icons.skip_next_rounded, '设为片头（$at）'),
        ),
        PopupMenuItem<int>(
          value: 1,
          enabled: !blocked,
          height: 40,
          child: _menuIconRow(Icons.skip_previous_rounded, '设为片尾（$at）'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<int>(
          value: 2,
          enabled: nav.openingMs > 0,
          height: 40,
          child: _menuIconRow(Icons.close_rounded, '清除片头'),
        ),
        PopupMenuItem<int>(
          value: 3,
          enabled: nav.endingMs > 0,
          height: 40,
          child: _menuIconRow(Icons.close_rounded, '清除片尾'),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    _onUserActivity();
    if (choice == 0) {
      if (!blocked) nav.onSetOpeningAt(clickedMs);
    } else if (choice == 1) {
      if (!blocked) nav.onSetEndingAt(clickedMs);
    } else if (choice == 2) {
      nav.onClearOpening();
    } else if (choice == 3) {
      nav.onClearEnding();
    }
  }

  /// 重播：回到起点后继续播放（不重新解析、不重建播放器）。
  void _handleReplay() {
    final nav = widget.replayNav;
    if (nav == null || nav.busy) return;
    nav.onReplay();
    _osdController.show(Icons.replay_rounded, '从头重播');
    _onUserActivity();
  }

  void _handleExit() {
    // §39：准备态（解析中 / 失败）优先取消，Esc 与返回键随时可用。
    if (widget.preparing != null) {
      final cancel = widget.onCancelPrepare;
      if (cancel != null) {
        _osdController.show(Icons.close_rounded, '已取消播放准备');
        cancel();
        return;
      }
    }
    // §20：抽屉打开时 Esc 先收抽屉，不退出全屏 / 不返回主视图。
    if (_episodeDrawerOpen) {
      _closeEpisodeDrawer();
      return;
    }
    // 画中画优先还原：Esc 是小窗的标准退出路径（skill `escape-routes`）。
    if (widget.windowManager.isPipNotifier.value) {
      unawaited(widget.windowManager.exitPip());
      _osdController.show(Icons.open_in_full_rounded, '已还原窗口');
      return;
    }
    if (widget.windowManager.isFullScreenNotifier.value) {
      widget.windowManager.toggleFullScreen();
      _osdController.show(Icons.fullscreen_exit_rounded, '退出全屏');
    } else if (widget.onBack != null) {
      widget.onBack!();
    }
  }

  /// 画面双击：正常态 = 全屏（既有语义）；PiP 内 = 先还原再全屏，保持
  /// 「双击进全屏」的直觉且状态干净。
  void _handleSurfaceDoubleTap() {
    final manager = widget.windowManager;
    if (manager.isPipNotifier.value) {
      unawaited(manager.exitPip().then((_) => manager.toggleFullScreen()));
      return;
    }
    manager.toggleFullScreen();
  }

  /// PiP 状态变化 → 重建（顶栏隐藏 / 底栏切换精简版）。
  void _onPipChanged() {
    if (mounted) setState(() {});
  }

  /// ⑤-3 修复：直播频道抽屉挂在「视频表面层」（控制条之下）。
  ///
  /// 层级（自下而上）：视频（含抽屉）→ 缓冲 / 错误 → OSD → 控制条。
  /// 顶栏 / 底栏渲染在抽屉之上，返回按钮、播放按钮、时间轴始终可见可点；
  /// 点播或无频道时直通，不产生任何包装层。
  Widget _wrapLiveLayer(Widget surface) {
    final channels = widget.liveChannels;
    if (channels == null || channels.isEmpty) return surface;
    return LiveChannelLayer(
      channels: channels,
      currentIndex: widget.liveCurrentIndex,
      // §35 方案 A：画中画小窗里不显示频道列表 —— 290px 抽屉在 400×225 的
      // 小窗里占掉 72% 宽，鼠标扫过左缘就整块盖住画面。
      enabled: !widget.windowManager.isPipNotifier.value,
      favoriteKeys: widget.liveFavoriteKeys,
      onSelect: widget.onLiveSelect ?? (_) {},
      onManage: widget.onLiveManage ?? () {},
      child: surface,
    );
  }

  /// §20 选集抽屉同样挂在「视频表面层」：控制条在它之上，
  /// 工具栏按钮可在抽屉打开时再点一次收起，Esc / 点遮罩也能关。
  Widget _wrapEpisodeLayer(Widget surface) {
    final nav = widget.episodeListNav;
    if (nav == null) return surface;
    return EpisodeDrawerLayer(
      open: _episodeDrawerOpen,
      nav: nav,
      onClose: _closeEpisodeDrawer,
      child: surface,
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final pip = widget.windowManager.isPipNotifier.value;
    return Shortcuts(
      shortcuts: defaultPlayerShortcuts,
      child: Actions(
        actions: {
          PlayPauseIntent: CallbackAction<PlayPauseIntent>(
              onInvoke: (_) => _togglePlayPause()),
          SeekIntent: CallbackAction<SeekIntent>(
            onInvoke: (i) {
              // ⑤-3 直播：←/→ 切台（点播仍为快退 / 快进）
              if (widget.playerEngine.currentSpec?.isLive == true) {
                final callback =
                    i.delta.isNegative ? widget.onLivePrev : widget.onLiveNext;
                if (callback != null) {
                  callback();
                  return null;
                }
              }
              _handleSeek(i.delta);
              return null;
            },
          ),
          VolumeIntent: CallbackAction<VolumeIntent>(
              onInvoke: (i) => _handleVolumeAdjust(i.delta)),
          ToggleMuteIntent: CallbackAction<ToggleMuteIntent>(
              onInvoke: (_) => _handleToggleMute()),
          ToggleFullscreenIntent: CallbackAction<ToggleFullscreenIntent>(
            onInvoke: (_) {
              final manager = widget.windowManager;
              if (manager.isPipNotifier.value) {
                // 小窗内 F / F11：先还原再全屏，避免「小窗全屏」怪状态。
                unawaited(
                    manager.exitPip().then((_) => manager.toggleFullScreen()));
                _osdController.show(Icons.fullscreen_rounded, '还原并全屏');
                return null;
              }
              manager.toggleFullScreen();
              _osdController.show(Icons.fullscreen_rounded, '切换全屏');
              return null;
            },
          ),
          ExitFullscreenIntent: CallbackAction<ExitFullscreenIntent>(
              onInvoke: (_) => _handleExit()),
          RateAdjustIntent: CallbackAction<RateAdjustIntent>(
            onInvoke: (i) => _handleRateAdjust(i.delta, reset: i.reset),
          ),
          PrevEpisodeIntent: CallbackAction<PrevEpisodeIntent>(
              onInvoke: (_) => _handlePrevEpisode()),
          NextEpisodeIntent: CallbackAction<NextEpisodeIntent>(
              onInvoke: (_) => _handleNextEpisode()),
          ToggleDanmakuIntent: CallbackAction<ToggleDanmakuIntent>(
              onInvoke: (_) => _handleToggleDanmaku()),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: MouseRegion(
            // §37：显隐判定改为「指针在不在顶/底热区」，不再按活动续命。
            onHover: (event) => _onChromeHover(event.localPosition),
            onExit: (_) => _onChromeExit(),
            cursor: _showControls
                ? SystemMouseCursors.basic
                : SystemMouseCursors.none,
            child: Stack(
              children: [
                // 1. MPV 原生 Direct3D 11 视频渲染表面
                //    双击切全屏只挂在这一层：控制条不参与双击判定，连点按钮不会误切全屏。
                Positioned.fill(
                  // §43 层级（2026-10-27 验收反馈）：弹幕在视频之上、选集抽屉之下——
                  // 抽屉打开时盖住弹幕，而不是弹幕从抽屉上飘过去。
                  child: _wrapEpisodeLayer(Stack(
                    fit: StackFit.expand,
                    children: [
                    _wrapLiveLayer(
                      LayoutBuilder(
                        builder: (context, constraints) => Listener(
                          // 表面层滚轮调音量：仅右半屏生效（左半屏无操作）。
                          onPointerSignal: (event) =>
                              _handleSurfacePointerSignal(
                                  event, constraints.maxWidth),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _togglePlayPause,
                            // PiP：按住画面拖动小窗（原生拖拽）；拖拽与点击由手势
                            // 竞技场区分，不影响单击播放/暂停。
                            onPanStart: pip
                                ? (_) => unawaited(
                                    widget.windowManager.startDragging())
                                : null,
                            onDoubleTap: _handleSurfaceDoubleTap,
                            child: widget.videoSurface ??
                                Video(
                                  controller:
                                      widget.playerEngine.videoController,
                                  controls: NoVideoControls,
                                  fit: videoFitForScale(widget.scale),
                                ),
                          ),
                        ),
                      ),
                    ),
                    // 1.5 §43 弹幕层：视频之上、选集抽屉与控制条之下；不接收指针（IgnorePointer）。
                    //     画中画小窗按设置的「画中画显示区域」（默认上 1/3）、字号缩小。
                    if (widget.danmakuNav != null)
                      Positioned.fill(child: _buildDanmakuLayer(pip: pip)),
                    ],
                  )),
                ),

                // 2. 中间缓冲与错误提示层
                Positioned.fill(
                  child: Center(
                    child: StreamBuilder<PlaybackStatus>(
                      stream: widget.playerEngine.statusStream,
                      initialData: widget.playerEngine.status,
                      builder: (context, snapshot) {
                        final status = snapshot.data;
                        if (status == PlaybackStatus.buffering) {
                          return CircularProgressIndicator(
                            color: context.palette.accentInk,
                            strokeWidth: 3.5,
                          );
                        }
                        if (status == PlaybackStatus.error) {
                          // ④：错误面板（渐进披露详情 + 复制诊断），见 PlaybackErrorPanel。
                          return PlaybackErrorPanel(
                            rawError: widget.playerEngine.currentError,
                            spec: widget.playerEngine.currentSpec,
                            engineLogs: widget.playerEngine.recentPlayerLogs,
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ),

                // 3. 屏幕实时交互浮层提示 (OSD)
                Positioned.fill(
                  child: PlayerOsdOverlay(controller: _osdController),
                ),

                // 4. 顶部半透明渐变控制条
                // §39：准备态期间顶栏常驻（否则返回按钮会随自动隐藏一起消失，
                // 而整屏准备浮层又挡住返回，用户就彻底没有出口了）。
                AnimatedPositioned(
                  duration: _chromeMotion(context,
                      visible: _showControls || widget.preparing != null),
                  top: (_showControls || widget.preparing != null) && !pip
                      ? 0
                      : -60,
                  height: 54,
                  left: 0,
                  right: 0,
                  child: Overlay.wrap(
                    clipBehavior: Clip.none,
                    child: Container(
                      key: const ValueKey('player-top-bar'),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [_chromeScrim, _chromeScrimFade],
                        ),
                      ),
                      child: Row(
                        children: [
                          if (widget.preparing != null &&
                              widget.onCancelPrepare != null)
                            FocusOutline(
                              radius: AppRadii.pill,
                              child: IconButton(
                                key: const ValueKey('player-back-cancel'),
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: _chromeInk),
                                tooltip: '取消并返回 (ESC)',
                                onPressed: widget.onCancelPrepare,
                              ),
                            )
                          else if (widget.onBack != null)
                            FocusOutline(
                              radius: AppRadii.pill,
                              child: IconButton(
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: _chromeInk),
                                tooltip: '返回 (ESC)',
                                onPressed: widget.onBack,
                              ),
                            ),
                          const SizedBox(width: 8),
                          // §38：沉浸时窗口没有自绘标题栏，顶栏空白处即拖动带。
                          Expanded(
                            child: GestureDetector(
                              key: const ValueKey('player-drag-region'),
                              behavior: HitTestBehavior.opaque,
                              onPanStart: _immersive
                                  ? (_) => unawaited(
                                      widget.windowManager.startDragging())
                                  : null,
                              child: Text(
                                widget.playerEngine.currentSpec?.title ?? '',
                                style: const TextStyle(
                                  color: _chromeInk,
                                  fontSize: AppType.title,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          // 硬解状态徽章
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _chromeBadge.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(AppRadii.xs),
                            ),
                            child: const Text(
                              'HW: D3D11',
                              style: TextStyle(
                                color: _chromeInk,
                                fontSize: AppType.caption,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          // §38：沉浸时窗口标题栏不渲染，最小化 / 最大化 / 关闭并到这里。
                          if (_immersive) ...[
                            const SizedBox(width: 4),
                            _buildWindowControls(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                // 5. 底栏隐藏时的常驻细进度线（贴窗口底、不可点击；无时长时不可见）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildMiniProgressLine(context),
                ),

                // 6. 底部播放控制面板
                AnimatedPositioned(
                  duration: _chromeMotion(context, visible: _showControls),
                  bottom: _showControls ? 0 : _bottomBarHideOffset,
                  left: 0,
                  right: 0,
                  child: Focus(
                    focusNode: _bottomBarFocusNode,
                    // 纯焦点信号监听，不进语义树（避免改变逐帧语义增量）。
                    includeSemantics: false,
                    child: pip
                        ? _buildPipCompactBar()
                        : Container(
                            key: const ValueKey('player-bottom-bar'),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [_chromeScrim, _chromeScrimFade],
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 进度条行：进度条 + 时间（时间固定在右端）
                                Row(
                                  children: [
                                    // 本地 Overlay：把滑条 OverlayPortal 的常驻子节点
                                    // 留在底栏子树内，底栏整体出屏/恢复时才不会出现
                                    // 「引用未提交节点」（语义增量回归；与音量滑条同范式）。
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder: (context, constraints) =>
                                            GestureDetector(
                                          // 时间轴右键：在点击处设置片头 / 片尾，或清除。
                                          onSecondaryTapUp: (details) =>
                                              _showTimelineMenu(details,
                                                  constraints.maxWidth),
                                          child: Overlay.wrap(
                                            alwaysSizeToContent: true,
                                            clipBehavior: Clip.none,
                                            child: _buildProgressBar(),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    _buildTimeLabel(),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                // 控制按钮行：一级动作（左）+ 音量 / 播放设置 / 全屏（右）
                                SizedBox(
                                  height: _controlRowHeight,
                                  child: Overlay.wrap(
                                    clipBehavior: Clip.none,
                                    child: Row(
                                      children: [
                                        _buildPlayPauseButton(),
                                        // §20 选集抽屉：集列表入口（与上/下一集相邻）
                                        if (widget.episodeListNav != null)
                                          _buildEpisodeButton(
                                            enabled: !widget
                                                .episodeListNav!.switching,
                                            icon: Icons.playlist_play_rounded,
                                            tooltip: '选集',
                                            onPressed: _toggleEpisodeDrawer,
                                          ),
                                        // 上一集 / 下一集（仅点播多集会话；边界与切换中禁用）
                                        if (widget.episodeNav != null) ...[
                                          _buildEpisodeButton(
                                            enabled: widget
                                                    .episodeNav!.canPrev &&
                                                !widget.episodeNav!.switching,
                                            icon: Icons.skip_previous_rounded,
                                            tooltip: '上一集 (PageUp)',
                                            onPressed: _handlePrevEpisode,
                                          ),
                                          _buildEpisodeButton(
                                            enabled: widget
                                                    .episodeNav!.canNext &&
                                                !widget.episodeNav!.switching,
                                            icon: Icons.skip_next_rounded,
                                            tooltip: '下一集 (PageDown)',
                                            onPressed: _handleNextEpisode,
                                          ),
                                        ],
                                        // 重播（回到起点继续播放）
                                        if (widget.replayNav != null)
                                          _buildEpisodeButton(
                                            enabled: !widget.replayNav!.busy,
                                            icon: Icons.replay_rounded,
                                            tooltip: '重播（从头开始）',
                                            onPressed: _handleReplay,
                                          ),
                                        // 倍速（HEAD 既有入口，文本本身承载当前值）
                                        _buildSpeedSelector(),
                                        const Spacer(),
                                        // 片头 / 片尾快速标记（音量左侧）
                                        _buildSkipMarkerButtons(),
                                        // §44 共享片段（与本地片头片尾是两个功能）
                                        if (widget.segmentsNav != null)
                                          _buildSegmentsButton(),
                                        // §43 弹幕开关（音量左侧）
                                        if (widget.danmakuNav != null)
                                          _buildDanmakuButton(),
                                        if (widget.danmakuNav
                                                ?.onSettingsChanged !=
                                            null)
                                          _buildDanmakuSettingsButton(),
                                        // 音量 / 播放设置 / 全屏（固定右侧）
                                        _buildVolumeControl(),
                                        if (_hasSettingsEntries)
                                          _buildSettingsButton(),
                                        _buildPipButton(),
                                        _buildFullscreenButton(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
                // 7. 跳过片头浮层胶囊（仅已设片头且当前仍在片头区间内出现）；
                //    §44 其上是共享片段的执行器（自动跳过 / 静音，1 票时的提示胶囊）。
                //
                // 位置固定在控制条之上（2026-10-27 实机反馈「点击时抽搐、点好几下点不到」）：
                // 原先 bottom 随控制条显隐在 96 / 24 之间跳，而 24 正落在底部热区里——
                // 鼠标移过去 → 控制条出现 → 胶囊跳走 → 鼠标出热区 → 控制条隐藏 → 胶囊落回，循环。
                // 现在固定 96，并且指针停在胶囊上时视作「在控制区」：控制条不隐藏、撤销倒计时暂停。
                Positioned(
                  right: 24,
                  bottom: 96,
                  child: MouseRegion(
                    onEnter: (_) {
                      _pointerOnPill = true;
                      _pointerInChrome = true;
                      _hideControlsTimer?.cancel();
                    },
                    onExit: (_) {
                      _pointerOnPill = false;
                    },
                    child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (widget.segmentsNav != null)
                        SegmentPlaybackRunner(
                          nav: widget.segmentsNav!,
                          engine: widget.playerEngine,
                          onNotice: _osdController.show,
                        ),
                      _buildSkipIntroPill(),
                    ],
                  ),
                  ),
                ),

                // 8. 起播准备态（§16）：解析地址期间盖在最上层。
                //    没有它时，弱网下点选集要干等几秒才进播放页。
                if (widget.preparing != null)
                  PlaybackPreparingOverlay(
                    intent: widget.preparing!,
                    onRetry: widget.onRetryPrepare,
                    onCancel: widget.onCancelPrepare,
                    // 让出顶栏高度，返回按钮才点得到。
                    topInset: pip ? 0 : 54,
                  ),

                // 9. §20 选集 + 线路抽屉挂在视频表面层（控制条之下，见 _wrapEpisodeLayer）。
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControlTooltip(
      {required String message, required Widget child}) {
    return Tooltip(
      message: message,
      positionDelegate: (position) {
        final aligned = positionDependentBox(
          size: position.overlaySize,
          childSize: position.tooltipSize,
          target: position.target,
          verticalOffset: position.verticalOffset,
          preferBelow: false,
        );
        // invariant: 浮层随按钮行隐藏，提示向视频内展开，不受按钮行高度挤压。
        return Offset(
          aligned.dx,
          position.target.dy -
              position.targetSize.height / 2 -
              position.tooltipSize.height -
              8,
        );
      },
      child: child,
    );
  }

  /// 控制条图标按钮（切集 / 重播 / 刷新）：禁用态灰显并吸收点击。
  Widget _buildEpisodeButton({
    required bool enabled,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final button = _buildBottomControlTooltip(
      message: tooltip,
      child: _ControlButton(
        icon: icon,
        onPressed: enabled ? onPressed : null,
      ),
    );
    if (enabled) return button;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: button,
    );
  }

  /// 控制条文本按钮（片头 / 片尾）：已设置显示时间，未设置显示名称。
  String _skipLabel(int ms, String fallback) =>
      ms > 0 ? _formatDuration(Duration(milliseconds: ms)) : fallback;

  /// §44 本集共享片段的时间轴色块（未配置服务 / 未加载完时为空）。
  Widget _withSegmentMarks(Widget Function(List<SegmentMark> marks) builder) {
    final nav = widget.segmentsNav;
    if (nav == null) return builder(const []);
    return ValueListenableBuilder<SegmentsState>(
      valueListenable: nav.state,
      builder: (context, state, _) => builder(
          segmentMarksFor(state, widget.playerEngine.duration.inMilliseconds)),
    );
  }

  Widget _buildProgressBar() {
    return _withSegmentMarks((marks) => StreamBuilder<Duration>(
      stream: widget.playerEngine.positionStream,
      initialData: widget.playerEngine.position,
      builder: (context, snapshot) {
        final posMs = _dragSeekPositionMs >= 0
            ? _dragSeekPositionMs
            : (snapshot.data?.inMilliseconds.toDouble() ?? 0.0);
        final durMs = widget.playerEngine.duration.inMilliseconds.toDouble();
        final maxVal = durMs > 0 ? durMs : 1.0;

        return MouseRegion(
          onEnter: (_) => setState(() => _progressHovered = true),
          onExit: (_) => setState(() => _progressHovered = false),
          child: TweenAnimationBuilder<double>(
            // 悬停加粗（B5）：轨道 3.5→6、滑点 6→7，200ms 过渡。
            tween: Tween<double>(end: _progressHovered ? 1.0 : 0.0),
            duration: _chromeMotion(context, visible: true),
            curve: AppMotion.ease,
            builder: (context, t, _) => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.5 + 2.5 * t,
                // §44 片段色块（片头片尾绿、广告黄……）画在轨道上、滑点之下
                trackShape: SegmentTrackShape(marks),
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6 + t),
                activeTrackColor: _chromeHighlight,
                inactiveTrackColor: _chromeTrack,
                thumbColor: _chromeInk,
                overlayColor: _chromeHighlight.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: posMs.clamp(0.0, maxVal),
                max: maxVal,
                onChanged: (val) {
                  setState(() => _dragSeekPositionMs = val);
                },
                onChangeEnd: (val) {
                  widget.playerEngine.seek(Duration(milliseconds: val.toInt()));
                  setState(() => _dragSeekPositionMs = -1.0);
                },
              ),
            ),
          ),
        );
      },
    ));
  }

  /// 控制条显隐 / 细线的动画时长（D2：进 200 / 出 140）。
  ///
  /// [visible] 为目标显隐态：显 → `AppMotion.enter`，隐 → `AppMotion.exit`。
  /// 鼠标与键盘路径都汇到 `_showControls` 这一处状态，节奏天然一致；
  /// 系统开启「减少动画」时瞬切（skill `reduced-motion`）。
  Duration _chromeMotion(BuildContext context, {required bool visible}) =>
      MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : (visible ? AppMotion.enter : AppMotion.exit);

  /// 底栏隐藏时的常驻细进度线：贴窗口最底、纯展示（`IgnorePointer`）。
  ///
  /// - 只反映播放位置（底栏隐藏时本就无法拖动进度）；
  /// - 直播等无时长（`duration == 0`）时不显示；
  /// - 控制条可见时透明（层级也在底栏之下，不干扰控制条）。
  ///
  /// 配色**刻意不随主题**（2026-10-27 实机反馈）：播放页底下永远是视频画面，
  /// 浅色主题的 `borderStrong`（#D2D2DC）/ `accentInk`（#334155）压上去又亮又脏。
  /// 这里直接取播放器 chrome 常量 `_chromeTrack` / `_chromeHighlight`，
  /// 它们与 `AppPalette.dark` 的对应值逐字节相同 —— 深色主题像素不变，
  /// 浅色主题则沿用深色那套。
  Widget _buildMiniProgressLine(BuildContext context) {
    return _withSegmentMarks((marks) => StreamBuilder<Duration>(
      stream: widget.playerEngine.positionStream,
      initialData: widget.playerEngine.position,
      builder: (context, snapshot) {
        final durMs = widget.playerEngine.duration.inMilliseconds;
        final hasDuration = durMs > 0;
        final posMs = (snapshot.data?.inMilliseconds ?? 0)
            .clamp(0, hasDuration ? durMs : 1);
        final fraction = hasDuration ? posMs / durMs : 0.0;
        final visible = !_showControls && hasDuration;
        return IgnorePointer(
          // 显示度用颜色 alpha 插值表达（不用 Opacity 包裹）：显隐
          // 不改变子树结构与语义节点。
          child: TweenAnimationBuilder<double>(
            key: const ValueKey('player-mini-progress'),
            tween: Tween<double>(end: visible ? 1.0 : 0.0),
            duration: _chromeMotion(context, visible: visible),
            builder: (context, alpha, _) => SizedBox(
              height: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: _chromeTrack.withValues(alpha: alpha)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: ColoredBox(
                        color: _chromeHighlight.withValues(alpha: alpha)),
                  ),
                  // §44 片段色块：与进度条同色，底栏隐藏后也看得到片头片尾 / 广告在哪
                  for (final m in marks)
                    FractionallySizedBox(
                      key: ValueKey('player-mini-segment-${m.id}'),
                      alignment: Alignment(
                          m.end - m.start >= 1 ? 0 : (m.start / (1 - (m.end - m.start))) * 2 - 1,
                          0),
                      widthFactor: m.end - m.start,
                      child: ColoredBox(
                          color: m.color.withValues(alpha: m.color.a * alpha)),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ));
  }

  // ---------------------------------------------------------------------------
  // SET-32 控制条精简：一级动作 + 播放设置面板 + 跳过片头浮层胶囊
  // ---------------------------------------------------------------------------

  /// 控制按钮行统一高度（图标 20 + 上下留白；点击区 36 由 `_ControlButton` 保证）。
  static const double _controlRowHeight = 44;

  Widget _buildPlayPauseButton() {
    return StreamBuilder<PlaybackStatus>(
      stream: widget.playerEngine.statusStream,
      initialData: widget.playerEngine.status,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data == PlaybackStatus.playing;
        return _buildBottomControlTooltip(
          message: isPlaying ? '暂停 (空格 / K)' : '播放 (空格 / K)',
          child: _ControlButton(
            icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            iconSize: 24,
            onPressed: _togglePlayPause,
          ),
        );
      },
    );
  }

  /// 片头 / 片尾快速标记按钮组（无视图模型时整组不显示）。
  Widget _buildSkipMarkerButtons() {
    if (widget.skipNav == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSkipMarkerButton(ending: false),
        _buildSkipMarkerButton(ending: true),
      ],
    );
  }

  /// 快速标记按钮：点击即把当前播放位置设为片头 / 片尾（校验在宿主）。
  Widget _buildSkipMarkerButton({required bool ending}) {
    final nav = widget.skipNav;
    if (nav == null) return const SizedBox.shrink();
    final valueMs = ending ? nav.endingMs : nav.openingMs;
    final label = ending ? '片尾' : '片头';
    final valueText =
        valueMs > 0 ? _formatDuration(Duration(milliseconds: valueMs)) : null;
    final message = valueText == null
        ? '$label（未设置）：点击设为当前位置'
        : (ending
            ? '$label（距结尾 $valueText）：点击设为当前位置'
            : '$label（当前 $valueText）：点击设为当前位置');
    return _buildBottomControlTooltip(
      message: message,
      child: FocusOutline(
        radius: AppRadii.pill,
        child: TextButton(
          onPressed: ending ? _handleEndingSkip : _handleOpeningSkip,
          style: TextButton.styleFrom(
            foregroundColor: valueMs > 0 ? _chromeHighlight : _chromeInk,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            overlayColor: _chromeInk.withValues(alpha: 0.12),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: AppType.body, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  /// 时间标签：固定在进度条行右端，不随任何滚动或按钮增减移动。
  Widget _buildTimeLabel() {
    return StreamBuilder<Duration>(
      stream: widget.playerEngine.positionStream,
      initialData: widget.playerEngine.position,
      builder: (context, snapshot) {
        final pos = snapshot.data ?? Duration.zero;
        final dur = widget.playerEngine.duration;
        return SizedBox(
          width: 108,
          child: Text(
            '${_formatDuration(pos)} / ${_formatDuration(dur)}',
            textAlign: TextAlign.right,
            style: const TextStyle(color: _chromeInk, fontSize: AppType.body),
          ),
        );
      },
    );
  }

  /// §43：D 键 / 「弹」按钮。打开时若还没加载完，OSD 给出当前进度。
  void _handleToggleDanmaku() {
    final nav = widget.danmakuNav;
    if (nav == null) return;
    final turningOn = !nav.enabled;
    nav.onToggle();
    final state = nav.state.value;
    _osdController.show(
      turningOn ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
      turningOn
          ? (state.phase == DanmakuLoadPhase.ready
              ? '弹幕已开启'
              : '弹幕已开启 · ${state.label}')
          : '弹幕已关闭',
    );
  }

  Widget _buildDanmakuLayer({required bool pip}) {
    final nav = widget.danmakuNav!;
    if (!nav.enabled) return const SizedBox.shrink();
    final settings = nav.settings;
    return ValueListenableBuilder<DanmakuState>(
      valueListenable: nav.state,
      builder: (context, state, _) {
        final track = state.track;
        if (state.phase != DanmakuLoadPhase.ready || track == null) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<PlaybackStatus>(
          stream: widget.playerEngine.statusStream,
          initialData: widget.playerEngine.status,
          builder: (context, status) => StreamBuilder<double>(
            stream: widget.playerEngine.rateStream,
            initialData: widget.playerEngine.rate,
            builder: (context, rate) => ValueListenableBuilder<bool>(
              valueListenable: widget.windowManager.isFullScreenNotifier,
              builder: (context, fullScreen, _) => LayoutBuilder(
                builder: (context, box) => DanmakuLayer(
                  key: ValueKey('danmaku-${state.requestKey}'),
                  track: track,
                  positionStream: widget.playerEngine.positionStream,
                  initialPosition: widget.playerEngine.position,
                  playing: status.data == PlaybackStatus.playing,
                  rate: rate.data ?? 1.0,
                  settings: settings,
                  fontSize: pip
                      ? pipDanmakuFontSize(settings.fontSize, box.maxHeight)
                      : (fullScreen
                          ? settings.fullscreenFontSize
                          : settings.fontSize),
                  area: pip ? settings.pipArea : settings.area,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// §44「片段」入口：右侧抽屉，提交本集片段（开始 / 结束 / 分类 / 动作）并查看他人共享的片段。
  Widget _buildSegmentsButton() {
    return _buildBottomControlTooltip(
      message: '片段（共享跳过）',
      child: _ControlButton(
        key: const ValueKey('player-segments'),
        icon: Icons.content_cut_rounded,
        onPressed: _openSegments,
      ),
    );
  }

  Future<void> _openSegments() async {
    final nav = widget.segmentsNav;
    if (nav == null) return;
    await _runSideDrawer(
      width: 380,
      barrierLabel: '关闭片段',
      builder: (_) => SegmentPanel(
        nav: nav,
        position: () => widget.playerEngine.position,
        duration: () => widget.playerEngine.duration,
        onSeek: (d) => unawaited(widget.playerEngine.seek(d)),
      ),
    );
  }

  /// §43 弹幕设置入口：右侧抽屉，播放中直接调外观 / 屏蔽 / 区域。
  Widget _buildDanmakuSettingsButton() {
    return _buildBottomControlTooltip(
      message: '弹幕设置',
      child: _ControlButton(
        key: const ValueKey('player-danmaku-settings'),
        icon: Icons.tune_rounded,
        onPressed: _openDanmakuSettings,
      ),
    );
  }

  Future<void> _openDanmakuSettings() async {
    final nav = widget.danmakuNav;
    final onChanged = nav?.onSettingsChanged;
    if (nav == null || onChanged == null) return;
    await _runSideDrawer(
      width: 360,
      barrierLabel: '关闭弹幕设置',
      builder: (_) => DanmakuSettingsPanel(
        initial: nav.settings,
        onChanged: onChanged,
        enabled: nav.enabled,
        // 走播放器自己的开关：读取的是**最新**的 danmakuNav，抽屉里连点不会错位
        onToggle: _handleToggleDanmaku,
      ),
    );
  }

  /// 「弹」按钮：开 / 关两种图标；开启且加载中时右上角一个小圆点。
  Widget _buildDanmakuButton() {
    final nav = widget.danmakuNav!;
    return ValueListenableBuilder<DanmakuState>(
      valueListenable: nav.state,
      builder: (context, state, _) {
        // 已加载时只提示快捷键；加载中 / 失败才附带状态（不显示条数）
        final tip = !nav.enabled
            ? '开启弹幕 (D)'
            : (state.phase == DanmakuLoadPhase.ready
                ? '关闭弹幕 (D)'
                : '关闭弹幕 (D) · ${state.label}');
        return _buildBottomControlTooltip(
          message: tip,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _ControlButton(
                key: const ValueKey('player-danmaku-toggle'),
                icon: nav.enabled
                    ? Icons.subtitles_rounded
                    : Icons.subtitles_off_rounded,
                iconSize: 21,
                onPressed: _handleToggleDanmaku,
              ),
              if (nav.enabled && state.busy)
                const Positioned(
                  right: 6,
                  top: 6,
                  child: SizedBox(
                    width: 6,
                    height: 6,
                    child: DecoratedBox(
                      key: ValueKey('player-danmaku-busy'),
                      decoration: BoxDecoration(
                          color: _chromeHighlight, shape: BoxShape.circle),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFullscreenButton() {
    return _buildBottomControlTooltip(
      message: '全屏 (F / F11 / 双击)',
      child: _ControlButton(
        icon: Icons.fullscreen_rounded,
        iconSize: 22,
        onPressed: () => widget.windowManager.toggleFullScreen(),
      ),
    );
  }

  /// 「画中画」入口：缩小为置顶小窗（无边框，Esc 还原；拖画面可换位）。
  Widget _buildPipButton() {
    return _buildBottomControlTooltip(
      message: '画中画（小窗悬浮播放，Esc 还原）',
      child: _ControlButton(
        icon: Icons.picture_in_picture_alt_rounded,
        iconSize: 22,
        onPressed: () => unawaited(widget.windowManager.enterPip()),
      ),
    );
  }

  /// PiP 精简控制条：还原 · 播放/暂停 · 进度与时间。
  ///
  /// 400×225 小窗容不下完整控制条（skill `Compact Control Semantics`：
  /// 只保留关键动作；还原另有 Esc，不只靠 hover）。
  /// §38：沉浸播放期间的窗口三键（标题栏已隐藏，这里是唯一入口）。
  Widget _buildWindowControls() {
    Widget button({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
    }) {
      return IconButton(
        key: key,
        iconSize: 17,
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        icon: Icon(icon, color: _chromeInk),
        onPressed: onPressed,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(
          key: const ValueKey('player-window-minimize'),
          tooltip: '最小化窗口',
          icon: Icons.remove_rounded,
          onPressed: () => unawaited(widget.windowManager.minimize()),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.windowManager.isMaximizedNotifier,
          builder: (context, maximized, _) => button(
            key: const ValueKey('player-window-maximize'),
            tooltip: maximized ? '还原窗口' : '最大化窗口',
            icon: maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            onPressed: () => unawaited(widget.windowManager.toggleMaximize()),
          ),
        ),
        button(
          key: const ValueKey('player-window-close'),
          tooltip: '关闭窗口',
          icon: Icons.close_rounded,
          onPressed: () => unawaited(widget.windowManager.close()),
        ),
      ],
    );
  }

  Widget _buildPipCompactBar() {
    return Container(
      key: const ValueKey('player-bottom-bar-pip'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [_chromeScrim, _chromeScrimFade],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Overlay.wrap(
                  alwaysSizeToContent: true,
                  clipBehavior: Clip.none,
                  child: _buildProgressBar(),
                ),
              ),
              const SizedBox(width: 10),
              _buildTimeLabel(),
            ],
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 40,
            child: Overlay.wrap(
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  _buildBottomControlTooltip(
                    message: '还原窗口 (Esc)',
                    child: _ControlButton(
                      icon: Icons.open_in_full_rounded,
                      iconSize: 22,
                      onPressed: () {
                        unawaited(widget.windowManager.exitPip());
                        _osdController.show(
                            Icons.open_in_full_rounded, '已还原窗口');
                      },
                    ),
                  ),
                  _buildPlayPauseButton(),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 只要还有任何「设置项」就显示齿轮入口，避免空面板。
  bool get _hasSettingsEntries =>
      widget.onScaleChanged != null ||
      widget.subtitleTracksNav != null ||
      widget.audioTracksNav != null ||
      widget.videoTracksNav != null ||
      widget.refreshNav != null ||
      widget.resetNav != null ||
      widget.skipNav != null ||
      (widget.playerInfoLabel?.trim().isNotEmpty ?? false);

  Widget _buildSettingsButton() {
    return _buildBottomControlTooltip(
      message: '播放设置',
      child: _ControlButton(
        icon: Icons.settings_rounded,
        onPressed: _openSettingsPanel,
      ),
    );
  }

  /// 面板是否已打开：防止连点齿轮叠出多层对话框。
  bool _panelOpen = false;

  /// 「播放设置」：§43 验收反馈后由居中对话框改为右侧抽屉（与「弹幕设置」同一形态）。
  Future<void> _openSettingsPanel() async {
    var panelAlive = true;
    await _runSideDrawer(
      width: 340,
      barrierLabel: '关闭设置',
      builder: (_) => StatefulBuilder(
        builder: (context, setPanelState) => _buildSettingsPanel(
          context,
          () {
            if (panelAlive) setPanelState(() {});
          },
        ),
      ),
    );
    panelAlive = false;
  }

  /// 打开右侧抽屉；同一时刻只开一个（防连点叠层），期间不自动隐藏控制条。
  Future<void> _runSideDrawer({
    required double width,
    required String barrierLabel,
    required WidgetBuilder builder,
  }) async {
    if (_panelOpen) return;
    _panelOpen = true;
    _onUserActivity();
    _hideControlsTimer?.cancel();
    try {
      await showPlayerSideDrawer<void>(
        context: context,
        width: width,
        barrierLabel: barrierLabel,
        builder: builder,
      );
    } finally {
      _panelOpen = false;
      if (mounted) _startHideTimer();
    }
  }

  Widget _buildSettingsPanel(BuildContext context, VoidCallback refreshPanel) {
    final imageRows = <Widget>[];
    final trackRows = <Widget>[];
    final lineRows = <Widget>[];
    final playRows = <Widget>[];
    final skipRows = <Widget>[];

    // 画面：画面比例（单选，与设置中心同源）
    if (widget.onScaleChanged != null) {
      imageRows.add(_buildScaleSelector(
        rowBuilder: (label) => _panelRow(
          icon: Icons.aspect_ratio_rounded,
          label: '画面比例',
        ),
        onSelectionHandled: refreshPanel,
      ));
    }

    // 轨道：字幕 / 音轨 / 视轨（各自内联列表）
    if (widget.subtitleTracksNav != null) {
      trackRows.add(_buildSubtitleSelector(
        rowBuilder: (tracks) => _panelRow(
          icon: Icons.subtitles_rounded,
          label: '字幕',
          value: tracks.any((t) => t.isSelected)
              ? tracks.firstWhere((t) => t.isSelected).displayName
              : '已关闭',
        ),
        onSelectionHandled: refreshPanel,
      ));
    }
    if (widget.audioTracksNav != null) {
      trackRows.add(_buildAudioSelector(
        rowBuilder: (tracks) => _panelRow(
          icon: Icons.audiotrack_rounded,
          label: '音轨',
          value: tracks.isEmpty
              ? null
              : tracks
                  .firstWhere((t) => t.isSelected, orElse: () => tracks.first)
                  .displayName,
        ),
        onSelectionHandled: refreshPanel,
      ));
    }
    if (widget.videoTracksNav != null) {
      trackRows.add(_buildVideoSelector(
        rowBuilder: (tracks, selectedId) => _panelRow(
          icon: Icons.video_settings_rounded,
          label: '视轨',
          value: switch (selectedId) {
            'auto' => '自动选择',
            'no' => '已关闭',
            _ => tracks
                .firstWhere((t) => 'video:${t.id}' == selectedId,
                    orElse: () => tracks.first)
                .displayName,
          },
        ),
        onSelectionHandled: refreshPanel,
      ));
    }

    // 播放：刷新
    final refreshNav = widget.refreshNav;
    if (refreshNav != null) {
      playRows.add(_panelActionRow(
        icon: Icons.refresh_rounded,
        label: '刷新',
        value: refreshNav.busy ? '刷新中…' : null,
        enabled: !refreshNav.busy,
        onTap: () {
          Navigator.of(context).pop();
          _handleRefresh();
        },
      ));
    }

    // 播放：片头 / 片尾（点击即设为当前位置；已设时行尾可清除）
    final skipNav = widget.skipNav;
    if (skipNav != null) {
      skipRows.add(_panelActionRow(
        icon: Icons.skip_next_rounded,
        label: '片头',
        value: _skipLabel(skipNav.openingMs, '未设置'),
        onTap: () {
          Navigator.of(context).pop();
          _handleOpeningSkip();
        },
        trailing: skipNav.openingMs > 0
            ? _buildPanelClearButton(
                tooltip: '清除片头',
                onPressed: () {
                  Navigator.of(context).pop();
                  _handleClearOpeningSkip();
                })
            : null,
      ));
      skipRows.add(_panelActionRow(
        icon: Icons.skip_previous_rounded,
        label: '片尾',
        value: _skipLabel(skipNav.endingMs, '未设置'),
        onTap: () {
          Navigator.of(context).pop();
          _handleEndingSkip();
        },
        trailing: skipNav.endingMs > 0
            ? _buildPanelClearButton(
                tooltip: '清除片尾',
                onPressed: () {
                  Navigator.of(context).pop();
                  _handleClearEndingSkip();
                })
            : null,
      ));
    }

    // 危险操作：重置（危险色，仍走确认框）
    final resetNav = widget.resetNav;
    if (resetNav != null) {
      playRows.add(_panelActionRow(
        icon: Icons.restart_alt_rounded,
        label: '重置播放器数据',
        danger: true,
        enabled: resetNav.enabled,
        onTap: () {
          Navigator.of(context).pop();
          _confirmReset();
        },
      ));
    }

    // 线路：手动换线（SET-12 重做）。当前线路勾选、已失败灰显，都不可点。
    final lineNav = widget.lineNav;
    if (lineNav != null && lineNav.options.length > 1) {
      for (final option in lineNav.options) {
        final enabled = !lineNav.busy && !option.current && !option.unavailable;
        lineRows.add(_panelActionRow(
          icon: option.current
              ? Icons.check_circle_rounded
              : Icons.swap_horiz_rounded,
          label: option.name,
          value: option.current ? '当前线路' : (option.unavailable ? '已失败' : null),
          enabled: enabled,
          onTap: () {
            Navigator.of(context).pop();
            lineNav.onSelect(option.index);
          },
        ));
      }
    }

    final sections = <Widget>[
      if (imageRows.isNotEmpty) ...[_panelSection('画面'), ...imageRows],
      if (trackRows.isNotEmpty) ...[_panelSection('轨道'), ...trackRows],
      if (lineRows.isNotEmpty) ...[_panelSection('线路'), ...lineRows],
      if (playRows.isNotEmpty) ...[_panelSection('播放'), ...playRows],
      if (skipRows.isNotEmpty) ...[_panelSection('跳过'), ...skipRows],
    ];

    final infoLabel = widget.playerInfoLabel?.trim() ?? '';
    return PlayerSideDrawerFrame(
      key: const ValueKey('player-settings-panel'),
      icon: Icons.settings_rounded,
      title: '播放设置',
      closeTooltip: '关闭设置',
      footer: infoLabel.isEmpty
          ? null
          : _panelRow(
              icon: Icons.info_outline_rounded,
              label: '播放器',
              value: infoLabel,
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sections,
      ),
    );
  }

  /// 面板分组标题。
  Widget _panelSection(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
      child: Text(
        title,
        style: TextStyle(
          color: context.palette.textDim,
          fontSize: AppType.caption,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 面板只读行 / 弹层入口行（点击由内层 `PopupMenuButton` 负责）。
  ///
  /// [trailing] 缺省为右向箭头；片头 / 片尾行在已设值时传入清除按钮。
  Widget _panelRow({
    required IconData icon,
    required String label,
    String? value,
    bool danger = false,
    Widget? trailing,
  }) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: danger
                    ? context.palette.danger
                    : context.palette.playerText.withValues(alpha: 0.7)),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: danger
                    ? context.palette.danger
                    : context.palette.playerText,
                fontSize: AppType.label,
              ),
            ),
            if (value == null)
              const Spacer()
            else
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: context.palette.textSub, fontSize: AppType.body),
                  ),
                ),
              ),
            trailing ??
                Icon(Icons.chevron_right_rounded,
                    size: 16, color: context.palette.textDim),
          ],
        ),
      ),
    );
  }

  /// 面板动作行（刷新 / 片头 / 片尾 / 重置）。
  Widget _panelActionRow({
    required IconData icon,
    required String label,
    String? value,
    bool enabled = true,
    bool danger = false,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    final row = _panelRow(
        icon: icon,
        label: label,
        value: value,
        danger: danger && enabled,
        trailing: trailing);
    return FocusOutline(
      radius: AppRadii.sm,
      inset: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 40,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Opacity(opacity: enabled ? 1.0 : 0.4, child: row),
        ),
      ),
    );
  }

  /// 面板行尾清除按钮（仅片头 / 片尾已设时出现）。
  Widget _buildPanelClearButton(
      {required String tooltip, required VoidCallback onPressed}) {
    return FocusOutline(
      radius: AppRadii.pill,
      child: IconButton(
        icon:
            Icon(Icons.close_rounded, size: 16, color: context.palette.textDim),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        onPressed: onPressed,
      ),
    );
  }

  /// 跳过片头胶囊：仅在已设片头且当前播放位置仍落在片头区间内时出现。
  Widget _buildSkipIntroPill() {
    final nav = widget.skipNav;
    if (nav == null || nav.openingMs <= 0 || !nav.enabled) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<Duration>(
      stream: widget.playerEngine.positionStream,
      initialData: widget.playerEngine.position,
      builder: (context, snapshot) {
        final posMs = (snapshot.data ?? Duration.zero).inMilliseconds;
        if (posMs < 0 || posMs >= nav.openingMs) {
          return const SizedBox.shrink();
        }
        return FocusOutline(
          radius: AppRadii.pill,
          // 胶囊是固定浅底深字（与主题无关）——焦点描边与悬停沿用同一固定
          // 深色系，保证压在任意画面上都清晰（focus-states / focus-appearance）。
          color: const Color(0xFF101014),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadii.pill),
              hoverColor: const Color(0xFF101014).withValues(alpha: 0.08),
              onTap: () {
                widget.playerEngine.seek(Duration(milliseconds: nav.openingMs));
                _osdController.show(Icons.skip_next_rounded, '已跳过片头');
                _onUserActivity();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  // 「跳过片头」胶囊固定浅底深字：压在任意视频画面上都要醒目，
                  // 与主题无关；下方文字与图标同属这套固定配色。
                  color: const Color(0xE6FFFFFF),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '跳过片头',
                      style: TextStyle(
                        color: Color(0xFF101014),
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(Icons.skip_next_rounded,
                        size: 16, color: Color(0xFF101014)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 菜单项「图标 + 文案」行（B5：轨道 / 倍速 / 时间轴菜单统一规格）。
  Widget _menuIconRow(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: context.palette.textDim),
        const SizedBox(width: AppSpacing.sm),
        Text(label, style: const TextStyle(fontSize: AppType.body)),
      ],
    );
  }

  Widget _buildSpeedSelector() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return StreamBuilder<double>(
      stream: widget.playerEngine.rateStream,
      initialData: widget.playerEngine.rate,
      builder: (context, snapshot) {
        final currentRate = snapshot.data ?? 1.0;
        return _buildBottomControlTooltip(
          message: '播放倍速 (C加速 / X减速 / Z重置)',
          child: FocusOutline(
            child: Theme(
              // 底栏文本控件 hover 统一为浅色 12%（默认主题 hover 在深底上不可辨）。
              data: Theme.of(context).copyWith(
                hoverColor: _chromeInk.withValues(alpha: 0.12),
              ),
              child: PopupMenuButton<double>(
                tooltip: '',
                color: context.palette.raised,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md)),
                onSelected: (rate) => widget.playerEngine.setRate(rate),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  child: Text(
                    '${currentRate}x',
                    style: const TextStyle(
                        color: _chromeInk,
                        fontSize: AppType.body,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                itemBuilder: (ctx) => speeds
                    .map((s) => CheckedPopupMenuItem<double>(
                          value: s,
                          height: 40,
                          checked: (s - currentRate).abs() < 0.001,
                          child: Text('${s}x',
                              style: const TextStyle(fontSize: AppType.body)),
                        ))
                    .toList(),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 播放器信息（SET-22 / SET-32）：作为设置面板底部的只读行展示，不再占用控制条。

  /// 字幕入口（SET-26 / SET-32）：面板行入口时由 `rowBuilder` 提供行内容。
  Widget _buildSubtitleSelector({
    Widget Function(List<TrackInfo> tracks)? rowBuilder,
    VoidCallback? onSelectionHandled,
  }) {
    final nav = widget.subtitleTracksNav;
    if (nav == null) return const SizedBox.shrink();
    return StreamBuilder<List<TrackInfo>>(
      stream: nav.tracksStream,
      initialData: nav.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? const <TrackInfo>[];
        final hasSelected = tracks.any((t) => t.isSelected);
        final canDisable = nav.onDisable != null;
        return _buildBottomControlTooltip(
          message: '字幕（开关 / 轨道）',
          child: FocusOutline(
            inset: const EdgeInsets.symmetric(horizontal: 8),
            child: PopupMenuButton<String>(
              tooltip: '',
              color: context.palette.raised,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md)),
              onSelected: (value) => unawaited(
                  _handleSubtitleSelected(value, tracks, nav)
                      .whenComplete(() => onSelectionHandled?.call())),
              child: rowBuilder?.call(tracks) ??
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Icon(Icons.subtitles_rounded,
                        color: _chromeInk, size: 20),
                  ),
              itemBuilder: (ctx) => [
                if (canDisable)
                  CheckedPopupMenuItem<String>(
                    value: 'off',
                    height: 40,
                    checked: !hasSelected,
                    child: const Text('关闭字幕',
                        style: TextStyle(fontSize: AppType.body)),
                  ),
                if (tracks.isEmpty)
                  PopupMenuItem<String>(
                    enabled: false,
                    height: 40,
                    child: Text('无可用字幕轨',
                        style: TextStyle(
                            fontSize: AppType.caption,
                            color: ctx.palette.textDim)),
                  )
                else
                  ...tracks.map((t) => CheckedPopupMenuItem<String>(
                        value: 'sub:${t.id}',
                        height: 40,
                        checked: t.isSelected,
                        child: _menuIconRow(
                            Icons.subtitles_rounded, t.displayName),
                      )),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 音轨入口（SET-27）：轨道勾选。
  /// 音轨入口（SET-27 / SET-32）：面板行入口时由 `rowBuilder` 提供行内容。
  Widget _buildAudioSelector({
    Widget Function(List<TrackInfo> tracks)? rowBuilder,
    VoidCallback? onSelectionHandled,
  }) {
    final nav = widget.audioTracksNav;
    if (nav == null) return const SizedBox.shrink();
    return StreamBuilder<List<TrackInfo>>(
      stream: nav.tracksStream,
      initialData: nav.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? const <TrackInfo>[];
        return _buildBottomControlTooltip(
          message: '音轨',
          child: FocusOutline(
            inset: const EdgeInsets.symmetric(horizontal: 8),
            child: PopupMenuButton<String>(
              tooltip: '',
              color: context.palette.raised,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md)),
              onSelected: (value) => unawaited(
                  _handleAudioSelected(value, tracks, nav)
                      .whenComplete(() => onSelectionHandled?.call())),
              child: rowBuilder?.call(tracks) ??
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Icon(Icons.audiotrack_rounded,
                        color: _chromeInk, size: 20),
                  ),
              itemBuilder: (ctx) => tracks.isEmpty
                  ? [
                      PopupMenuItem<String>(
                        enabled: false,
                        height: 40,
                        child: Text('无可用音轨',
                            style: TextStyle(
                                fontSize: AppType.caption,
                                color: ctx.palette.textDim)),
                      ),
                    ]
                  : tracks
                      .map((t) => CheckedPopupMenuItem<String>(
                            value: 'audio:${t.id}',
                            height: 40,
                            checked: t.isSelected,
                            child: _menuIconRow(
                                Icons.audiotrack_rounded, t.displayName),
                          ))
                      .toList(),
            ),
          ),
        );
      },
    );
  }

  /// 视轨入口（SET-28 / SET-32）：面板行入口时由 `rowBuilder` 提供行内容。
  Widget _buildVideoSelector({
    Widget Function(List<TrackInfo> tracks, String selectedId)? rowBuilder,
    VoidCallback? onSelectionHandled,
  }) {
    final nav = widget.videoTracksNav;
    if (nav == null) return const SizedBox.shrink();
    return StreamBuilder<List<TrackInfo>>(
      stream: nav.tracksStream,
      initialData: nav.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? const <TrackInfo>[];
        final selectedId = _videoSelectionOverride ??
            (nav.isDisabled
                ? 'no'
                : (tracks.any((t) => t.isSelected)
                    ? 'video:${tracks.firstWhere((t) => t.isSelected).id}'
                    : 'auto'));
        return _buildBottomControlTooltip(
          message: '视轨',
          child: FocusOutline(
            inset: const EdgeInsets.symmetric(horizontal: 8),
            child: PopupMenuButton<String>(
              tooltip: '',
              color: context.palette.raised,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.md)),
              onSelected: (value) => unawaited(
                  _handleVideoSelected(value, tracks, nav)
                      .whenComplete(() => onSelectionHandled?.call())),
              child: rowBuilder?.call(tracks, selectedId) ??
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Icon(Icons.video_settings_rounded,
                        color: _chromeInk, size: 20),
                  ),
              itemBuilder: (ctx) => [
                CheckedPopupMenuItem<String>(
                  value: 'auto',
                  height: 40,
                  checked: selectedId == 'auto',
                  child: const Text('自动',
                      style: TextStyle(fontSize: AppType.body)),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'no',
                  height: 40,
                  checked: selectedId == 'no',
                  child: const Text('关闭',
                      style: TextStyle(fontSize: AppType.body)),
                ),
                ...tracks.map((t) => CheckedPopupMenuItem<String>(
                      value: 'video:${t.id}',
                      height: 40,
                      checked: selectedId == 'video:${t.id}',
                      child: _menuIconRow(
                          Icons.video_settings_rounded, t.displayName),
                    )),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 画面比例（SET-30 / SET-32）：面板行入口时由 `rowBuilder` 提供行内容。
  Widget _buildScaleSelector({
    Widget Function(String label)? rowBuilder,
    VoidCallback? onSelectionHandled,
  }) {
    if (widget.onScaleChanged == null) return const SizedBox.shrink();
    const options = PlayerSettings.scaleOptions;
    final current = widget.scale;
    final currentLabel = PlayerSettings.labelOf(options, current);
    return _buildBottomControlTooltip(
      message: '画面比例（当前：$currentLabel）',
      child: FocusOutline(
        inset: const EdgeInsets.symmetric(horizontal: 8),
        child: PopupMenuButton<String>(
          tooltip: '',
          color: context.palette.raised,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md)),
          onSelected: (value) => unawaited(_handleScaleSelected(value)
              .whenComplete(() => onSelectionHandled?.call())),
          child: rowBuilder?.call(currentLabel) ??
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Icon(Icons.aspect_ratio_rounded,
                    color: _chromeInk, size: 20),
              ),
          itemBuilder: (ctx) => options
              .map((o) => CheckedPopupMenuItem<String>(
                    value: o.value,
                    height: 40,
                    checked: o.value == current,
                    child: Text(o.label,
                        style: const TextStyle(fontSize: AppType.body)),
                  ))
              .toList(),
        ),
      ),
    );
  }

  Future<void> _handleSubtitleSelected(
      String value, List<TrackInfo> tracks, PlayerSubtitleTracksNav nav) async {
    try {
      if (value == 'off') {
        final disable = nav.onDisable;
        if (disable == null) return;
        await disable();
        if (!mounted) return;
        _osdController.show(Icons.subtitles_off_rounded, '字幕: 已关闭');
        return;
      }
      final track = tracks.firstWhere((t) => 'sub:${t.id}' == value);
      await nav.onSelect(track);
      if (!mounted) return;
      _osdController.show(Icons.subtitles_rounded, '字幕: ${track.displayName}');
    } catch (_) {
      if (!mounted) return;
      _osdController.show(Icons.error_outline_rounded, '切换失败，请稍后再试');
    }
  }

  Future<void> _handleAudioSelected(
      String value, List<TrackInfo> tracks, PlayerAudioTracksNav nav) async {
    try {
      final track = tracks.firstWhere((t) => 'audio:${t.id}' == value);
      await nav.onSelect(track);
      if (!mounted) return;
      _osdController.show(Icons.audiotrack_rounded, '音轨: ${track.displayName}');
    } catch (_) {
      if (!mounted) return;
      _osdController.show(Icons.error_outline_rounded, '切换失败，请稍后再试');
    }
  }

  Future<void> _handleVideoSelected(
      String value, List<TrackInfo> tracks, PlayerVideoTracksNav nav) async {
    try {
      final TrackInfo track;
      if (value == 'auto') {
        track = const TrackInfo(id: 'auto', type: TrackType.video, title: '自动');
      } else if (value == 'no') {
        track = const TrackInfo(id: 'no', type: TrackType.video, title: '关闭');
      } else {
        track = tracks.firstWhere((t) => 'video:${t.id}' == value);
      }
      await nav.onSelect(track);
      if (!mounted) return;
      setState(() => _videoSelectionOverride = value);
      _osdController.show(
          Icons.video_settings_rounded, '视轨: ${track.displayName}');
    } catch (_) {
      if (!mounted) return;
      _osdController.show(Icons.error_outline_rounded, '切换失败，请稍后再试');
    }
  }

  Future<void> _handleScaleSelected(String value) async {
    final callback = widget.onScaleChanged;
    if (callback == null) return;
    try {
      await callback(value);
      if (!mounted) return;
      _osdController.show(
        Icons.aspect_ratio_rounded,
        '画面比例: ${PlayerSettings.labelOf(PlayerSettings.scaleOptions, value)}',
      );
    } catch (_) {
      if (!mounted) return;
      _osdController.show(Icons.error_outline_rounded, '画面比例保存失败，请重试');
    }
  }

  Future<void> _confirmReset() async {
    final nav = widget.resetNav;
    if (nav == null || !nav.enabled) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置播放器数据'),
        content: const Text('将还原当前影片的片头 / 片尾、播放器设置与画面比例为默认值。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            // 「重置」是破坏性操作，按 destructive-emphasis 用危险色
            child: Text('重置', style: TextStyle(color: context.palette.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await nav.onReset();
      if (!mounted) return;
      _osdController.show(Icons.restart_alt_rounded, '已重置播放器数据');
    } catch (_) {
      if (!mounted) return;
      _osdController.show(Icons.error_outline_rounded, '重置失败，请稍后再试');
    }
  }

  Widget _buildVolumeControl() {
    return StreamBuilder<double>(
      stream: widget.playerEngine.volumeStream,
      initialData: widget.playerEngine.volume,
      builder: (context, snapshot) {
        final vol = snapshot.data ?? 100.0;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBottomControlTooltip(
              message: vol == 0 ? '取消静音 (M)' : '静音 (M)',
              child: _ControlButton(
                icon: vol == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                onPressed: _handleToggleMute,
              ),
            ),
            SizedBox(
              width: 70,
              child: Overlay.wrap(
                alwaysSizeToContent: true,
                clipBehavior: Clip.none,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 4),
                    activeTrackColor: _chromeInk,
                    inactiveTrackColor: _chromeTrack,
                    thumbColor: _chromeInk,
                  ),
                  child: Slider(
                    value: vol.clamp(0.0, 100.0),
                    max: 100.0,
                    onChanged: (v) => widget.playerEngine.setVolume(v),
                    // 拖动过程只改即时音量；松手才上报（§36），避免高频写盘。
                    onChangeEnd: (v) {
                      if (v > 0) _lastUnmutedVolume = v;
                      _commitVolume(v);
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 控制条统一图标按钮（SET-32）：36×36 点击区、20px 图标、圆形 hover 高亮。
///
/// 收缩尺寸后同一行可容纳更多入口而不溢出；tooltip 由调用方
/// 用 `_buildBottomControlTooltip` 统一包裹，避免两套定位逻辑。
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final VoidCallback? onPressed;

  const _ControlButton({
    super.key,
    required this.icon,
    this.iconSize = 20,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return FocusOutline(
      radius: AppRadii.pill,
      child: IconButton(
        icon: Icon(
          icon,
          size: iconSize,
          color: enabled ? _chromeInk : _chromeInk.withValues(alpha: 0.38),
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        visualDensity: VisualDensity.compact,
        splashRadius: 18,
        hoverColor: _chromeInk.withValues(alpha: 0.12),
        onPressed: onPressed,
      ),
    );
  }
}
