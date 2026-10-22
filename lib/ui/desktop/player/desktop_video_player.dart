import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../core/config/models/vod_config.dart';
import '../../../core/player/models/player_settings.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/player/models/track_info.dart';
import '../../../core/player/mpv_player_engine.dart';
import '../../../core/player/playback_intent.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../keyboard/player_shortcuts.dart';
import 'episode_drawer.dart';
import 'playback_preparing_overlay.dart';
import '../widgets/focus_ring.dart';
import '../window/desktop_window_manager.dart';
import 'live_channel_drawer.dart';
import 'playback_error_panel.dart';
import 'player_osd_overlay.dart';

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

  /// 抽屉选台回调；[liveChannels] 为空时不会触发。
  final ValueChanged<int>? onLiveSelect;

  /// 抽屉「管理频道」入口回调。
  final VoidCallback? onLiveManage;

  /// 起播准备态（§16）：非空时在画面上盖一层骨架/失败面板。
  ///
  /// 解析播放地址在弱网下要几秒；把播放页先亮出来、状态放页内，
  /// 用户点完立刻有反馈，且失败可原地重试。
  final PlaybackIntent? preparing;

  /// 准备失败时的「重试」回调。
  final VoidCallback? onRetryPrepare;

  /// 准备态的「返回」回调（退出准备态回到列表）。
  final VoidCallback? onCancelPrepare;
  const DesktopVideoPlayer({
    super.key,
    required this.playerEngine,
    required this.windowManager,
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
    this.onLiveSelect,
    this.onLiveManage,
    this.preparing,
    this.onRetryPrepare,
    this.onCancelPrepare,
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

  @override
  void initState() {
    super.initState();
    widget.windowManager.isPipNotifier.addListener(_onPipChanged);
    _bottomBarFocusNode.addListener(_onBottomBarFocusChanged);
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
    // 会话关闭 / 切成直播：抽屉没有内容可列，直接收起（避免空面板挂屏）。
    if (widget.episodeListNav == null && _episodeDrawerOpen) {
      _episodeDrawerOpen = false;
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    widget.windowManager.isPipNotifier.removeListener(_onPipChanged);
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

  void _startHideTimer() {
    _hideControlsTimer?.cancel();
    // 焦点在控制条内时不自动隐藏（WCAG 2.2 focus-not-obscured）。
    if (_bottomBarHasFocus || _episodeDrawerOpen) return;
    if (widget.playerEngine.status == PlaybackStatus.playing) {
      _hideControlsTimer = Timer(_hideDelay, () {
        if (mounted && widget.playerEngine.status == PlaybackStatus.playing) {
          setState(() => _showControls = false);
        }
      });
    }
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
    _onUserActivity();
  }

  void _handleToggleMute() {
    final currentVol = widget.playerEngine.volume;
    if (currentVol > 0) {
      _lastUnmutedVolume = currentVol;
      widget.playerEngine.setVolume(0.0);
      _osdController.show(Icons.volume_off_rounded, '已静音');
    } else {
      final restoreVol = _lastUnmutedVolume > 0 ? _lastUnmutedVolume : 100.0;
      widget.playerEngine.setVolume(restoreVol);
      _osdController.show(
          Icons.volume_up_rounded, '音量: ${restoreVol.toInt()}%');
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
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: MouseRegion(
            onHover: (_) => _onUserActivity(),
            cursor: _showControls
                ? SystemMouseCursors.basic
                : SystemMouseCursors.none,
            child: Stack(
              children: [
                // 1. MPV 原生 Direct3D 11 视频渲染表面
                //    双击切全屏只挂在这一层：控制条不参与双击判定，连点按钮不会误切全屏。
                Positioned.fill(
                  child: _wrapEpisodeLayer(
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
                  ),
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
                AnimatedPositioned(
                  duration: _chromeMotion(context, visible: _showControls),
                  top: _showControls && !pip ? 0 : -60,
                  height: 54,
                  left: 0,
                  right: 0,
                  child: Overlay.wrap(
                    clipBehavior: Clip.none,
                    child: Container(
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
                          if (widget.onBack != null)
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
                          Expanded(
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
                // 7. 跳过片头浮层胶囊（仅已设片头且当前仍在片头区间内出现）
                Positioned(
                  right: 24,
                  bottom: _showControls ? 96 : 24,
                  child: _buildSkipIntroPill(),
                ),

                // 8. 起播准备态（§16）：解析地址期间盖在最上层。
                //    没有它时，弱网下点选集要干等几秒才进播放页。
                if (widget.preparing != null)
                  PlaybackPreparingOverlay(
                    intent: widget.preparing!,
                    onRetry: widget.onRetryPrepare,
                    onCancel: widget.onCancelPrepare,
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

  Widget _buildProgressBar() {
    return StreamBuilder<Duration>(
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
    );
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
  Widget _buildMiniProgressLine(BuildContext context) {
    return StreamBuilder<Duration>(
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
                  ColoredBox(
                      color: context.palette.borderStrong
                          .withValues(alpha: alpha)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: ColoredBox(
                        color:
                            context.palette.accentInk.withValues(alpha: alpha)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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

  Future<void> _openSettingsPanel() async {
    if (_panelOpen) return;
    _panelOpen = true;
    _onUserActivity();
    _hideControlsTimer?.cancel();
    var panelAlive = true;
    try {
      await showDialog<void>(
        context: context,
        // 模态遮罩固定压暗：无论深/浅主题，背后的视频都应退到背景。
        barrierColor: const Color(0x66000000),
        // 必须提供 Center：Overlay 给非 Positioned 子节点的是整屏 tight 约束，
        // 缺了它 Container(width: 340) 会被强制拉成整屏。
        builder: (dialogContext) => Center(
          child: Material(
            type: MaterialType.transparency,
            // 面板内行 hover 统一为主题前景 8%（默认主题 hover 在深底上几乎不可见）。
            child: Theme(
              data: Theme.of(dialogContext).copyWith(
                hoverColor: AppPalette.of(dialogContext)
                    .playerText
                    .withValues(alpha: 0.08),
              ),
              child: StatefulBuilder(
                builder: (context, setPanelState) => _buildSettingsPanel(
                  context,
                  () {
                    if (panelAlive) setPanelState(() {});
                  },
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      panelAlive = false;
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
        final enabled =
            !lineNav.busy && !option.current && !option.unavailable;
        lineRows.add(_panelActionRow(
          icon: option.current
              ? Icons.check_circle_rounded
              : Icons.swap_horiz_rounded,
          label: option.name,
          value: option.current
              ? '当前线路'
              : (option.unavailable ? '已失败' : null),
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
    return Container(
      key: const ValueKey('player-settings-panel'),
      width: 340,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: context.palette.playerChrome,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(
            color: context.palette.playerText.withValues(alpha: 0.12)),
        boxShadow: const [
          BoxShadow(
            // 面板投影固定黑色：浅色主题下也符合「浮在视频上」的投影直觉。
            color: Color(0x99000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                // 图标块 + 标题：与 B4 弹窗头部同一头部语言。
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: context.palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Icon(Icons.settings_rounded,
                      color: context.palette.accentInk, size: 16),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '播放设置',
                  style: TextStyle(
                    color: context.palette.playerText,
                    fontSize: AppType.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                FocusOutline(
                  radius: AppRadii.pill,
                  child: IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: context.palette.playerText, size: 18),
                    tooltip: '关闭设置',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
          Divider(
              height: 1,
              thickness: 1,
              color: context.palette.playerText.withValues(alpha: 0.08)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...sections,
                  if (infoLabel.isNotEmpty) ...[
                    Divider(
                        height: 9,
                        thickness: 1,
                        color:
                            context.palette.playerText.withValues(alpha: 0.08)),
                    _panelRow(
                      icon: Icons.info_outline_rounded,
                      label: '播放器',
                      value: infoLabel,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
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
