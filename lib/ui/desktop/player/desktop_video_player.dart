import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../core/player/models/player_settings.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/player/models/track_info.dart';
import '../../../core/player/mpv_player_engine.dart';
import '../../../core/player/playback_error_text.dart';
import '../keyboard/player_shortcuts.dart';
import '../window/desktop_window_manager.dart';
import 'player_osd_overlay.dart';

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
class PlayerSkipNav {
  final int openingMs;
  final int endingMs;

  /// 片头片尾总开关；关闭时「跳过片头」胶囊不应出现。
  final bool enabled;

  final VoidCallback onOpeningPressed;
  final VoidCallback onEndingPressed;

  const PlayerSkipNav({
    this.openingMs = 0,
    this.endingMs = 0,
    this.enabled = true,
    required this.onOpeningPressed,
    required this.onEndingPressed,
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
  final bool tried;

  const PlayerLineOption({
    required this.index,
    required this.name,
    this.current = false,
    this.tried = false,
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

  const DesktopVideoPlayer({
    super.key,
    required this.playerEngine,
    required this.windowManager,
    this.scale = 'fit',
    this.onBack,
    this.videoSurface,
    this.episodeNav,
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

  double _dragSeekPositionMs = -1.0;
  double _lastUnmutedVolume = 100.0;

  /// 视轨菜单最近一次成功选择（`auto` / `no` / `video:<id>`），用于关闭态勾选。
  String? _videoSelectionOverride;

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
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
    if (widget.playerEngine.status == PlaybackStatus.playing) {
      _hideControlsTimer = Timer(_hideDelay, () {
        if (mounted && widget.playerEngine.status == PlaybackStatus.playing) {
          setState(() => _showControls = false);
        }
      });
    }
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
    final targetMs = (curPos.inMilliseconds + delta.inMilliseconds).clamp(0, dur.inMilliseconds);
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
      _osdController.show(Icons.volume_up_rounded, '音量: ${restoreVol.toInt()}%');
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
    nav.onOpeningPressed();
    _onUserActivity();
  }

  void _handleEndingSkip() {
    final nav = widget.skipNav;
    if (nav == null) return;
    nav.onEndingPressed();
    _onUserActivity();
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
    if (widget.windowManager.isFullScreenNotifier.value) {
      widget.windowManager.toggleFullScreen();
      _osdController.show(Icons.fullscreen_exit_rounded, '退出全屏');
    } else if (widget.onBack != null) {
      widget.onBack!();
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: defaultPlayerShortcuts,
      child: Actions(
        actions: {
          PlayPauseIntent: CallbackAction<PlayPauseIntent>(onInvoke: (_) => _togglePlayPause()),
          SeekIntent: CallbackAction<SeekIntent>(onInvoke: (i) => _handleSeek(i.delta)),
          VolumeIntent: CallbackAction<VolumeIntent>(onInvoke: (i) => _handleVolumeAdjust(i.delta)),
          ToggleMuteIntent: CallbackAction<ToggleMuteIntent>(onInvoke: (_) => _handleToggleMute()),
          ToggleFullscreenIntent: CallbackAction<ToggleFullscreenIntent>(
            onInvoke: (_) {
              widget.windowManager.toggleFullScreen();
              _osdController.show(Icons.fullscreen_rounded, '切换全屏');
              return null;
            },
          ),
          ExitFullscreenIntent: CallbackAction<ExitFullscreenIntent>(onInvoke: (_) => _handleExit()),
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
            cursor: _showControls ? SystemMouseCursors.basic : SystemMouseCursors.none,
            child: Stack(
                children: [
                  // 1. MPV 原生 Direct3D 11 视频渲染表面
                  //    双击切全屏只挂在这一层：控制条不参与双击判定，连点按钮不会误切全屏。
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _togglePlayPause,
                      onDoubleTap: () =>
                          widget.windowManager.toggleFullScreen(),
                      child: widget.videoSurface ??
                          Video(
                            controller: widget.playerEngine.videoController,
                            controls: NoVideoControls,
                            fit: videoFitForScale(widget.scale),
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
                            return const CircularProgressIndicator(
                              color: Color(0xFFE50914),
                              strokeWidth: 3.5,
                            );
                          }
                          if (status == PlaybackStatus.error) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xCC000000),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                              ),
                              child: Text(
                                friendlyPlaybackError(
                                    widget.playerEngine.currentError),
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                              ),
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
                    duration: const Duration(milliseconds: 200),
                    top: _showControls ? 0 : -60,
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
                            colors: [Color(0xB3000000), Color(0x00000000)],
                          ),
                        ),
                        child: Row(
                          children: [
                            if (widget.onBack != null)
                              IconButton(
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: Colors.white),
                                tooltip: '返回 (ESC)',
                                onPressed: widget.onBack,
                              ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.playerEngine.currentSpec?.title ?? '',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
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
                                color: const Color(0xFFE50914)
                                    .withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'HW: D3D11',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 5. 底部播放控制面板
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 200),
                    bottom: _showControls ? 0 : -80,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xCC000000), Color(0x00000000)],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 进度条行：进度条 + 时间（时间固定在右端）
                          Row(
                            children: [
                              Expanded(child: _buildProgressBar()),
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
                                  // 上一集 / 下一集（仅点播多集会话；边界与切换中禁用）
                                  if (widget.episodeNav != null) ...[
                                    _buildEpisodeButton(
                                      enabled: widget.episodeNav!.canPrev &&
                                          !widget.episodeNav!.switching,
                                      icon: Icons.skip_previous_rounded,
                                      tooltip: '上一集 (PageUp)',
                                      onPressed: _handlePrevEpisode,
                                    ),
                                    _buildEpisodeButton(
                                      enabled: widget.episodeNav!.canNext &&
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
                                  // 音量 / 播放设置 / 全屏（固定右侧）
                                  _buildVolumeControl(),
                                  if (_hasSettingsEntries)
                                    _buildSettingsButton(),
                                  _buildFullscreenButton(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 5. 跳过片头浮层胶囊（仅已设片头且当前仍在片头区间内出现）
                  Positioned(
                    right: 24,
                    bottom: _showControls ? 96 : 24,
                    child: _buildSkipIntroPill(),
                  ),
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

        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            activeTrackColor: const Color(0xFFE50914),
            inactiveTrackColor: const Color(0xFF40404C),
            thumbColor: Colors.white,
            overlayColor: const Color(0x33E50914),
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
            style: const TextStyle(color: Color(0xFFC0C0D0), fontSize: 12),
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
        barrierColor: const Color(0x66000000),
        // 必须提供 Center：Overlay 给非 Positioned 子节点的是整屏 tight 约束，
        // 缺了它 Container(width: 340) 会被强制拉成整屏。
        builder: (dialogContext) => Center(
          child: Material(
            type: MaterialType.transparency,
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
                  .firstWhere((t) => t.isSelected,
                      orElse: () => tracks.first)
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

    // 播放：片头 / 片尾（配置动作；打开宿主面板前先收起本面板）
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
      ));
      skipRows.add(_panelActionRow(
        icon: Icons.skip_previous_rounded,
        label: '片尾',
        value: _skipLabel(skipNav.endingMs, '未设置'),
        onTap: () {
          Navigator.of(context).pop();
          _handleEndingSkip();
        },
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
        final enabled = !lineNav.busy && !option.current && !option.tried;
        lineRows.add(_panelActionRow(
          icon: option.current
              ? Icons.check_circle_rounded
              : Icons.swap_horiz_rounded,
          label: option.name,
          value: option.current
              ? '当前线路'
              : (option.tried ? '已失败' : null),
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
        color: const Color(0xF21C1C22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x1FFFFFFF)),
        boxShadow: const [
          BoxShadow(
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
                const Text(
                  '播放设置',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Color(0xFFB0B0C0), size: 18),
                  tooltip: '关闭设置',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: Color(0x14FFFFFF)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...sections,
                  if (infoLabel.isNotEmpty) ...[
                    const Divider(
                        height: 9, thickness: 1, color: Color(0x14FFFFFF)),
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
        style: const TextStyle(
          color: Color(0xFF80809A),
          fontSize: 11,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 面板只读行 / 弹层入口行（点击由内层 `PopupMenuButton` 负责）。
  Widget _panelRow({
    required IconData icon,
    required String label,
    String? value,
    bool danger = false,
  }) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: danger ? const Color(0xFFFF6B6B) : Colors.white70),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: danger ? const Color(0xFFFF6B6B) : Colors.white,
                fontSize: 13,
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
                    style: const TextStyle(
                        color: Color(0xFF9A9AAA), fontSize: 12),
                  ),
                ),
              ),
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: Color(0xFF6A6A7A)),
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
    required VoidCallback onTap,
  }) {
    final row = _panelRow(
        icon: icon, label: label, value: value, danger: danger && enabled);
    return SizedBox(
      height: 40,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Opacity(opacity: enabled ? 1.0 : 0.4, child: row),
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
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              widget.playerEngine
                  .seek(Duration(milliseconds: nav.openingMs));
              _osdController.show(Icons.skip_next_rounded, '已跳过片头');
              _onUserActivity();
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xE6FFFFFF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '跳过片头',
                    style: TextStyle(
                      color: Color(0xFF101014),
                      fontSize: 12,
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
        );
      },
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
          child: PopupMenuButton<double>(
            tooltip: '',
            initialValue: currentRate,
            onSelected: (rate) => widget.playerEngine.setRate(rate),
            color: const Color(0xFF202028),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                '${currentRate}x',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
            itemBuilder: (ctx) => speeds
                .map((s) => PopupMenuItem(
                      value: s,
                      height: 32,
                      child:
                          Text('${s}x', style: const TextStyle(fontSize: 12)),
                    ))
                .toList(),
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
          child: PopupMenuButton<String>(
            tooltip: '',
            color: const Color(0xFF202028),
            onSelected: (value) => unawaited(_handleSubtitleSelected(
                    value, tracks, nav)
                .whenComplete(() => onSelectionHandled?.call())),
            child: rowBuilder?.call(tracks) ??
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Icon(Icons.subtitles_rounded,
                      color: Colors.white, size: 20),
                ),
            itemBuilder: (ctx) => [
              if (canDisable)
                CheckedPopupMenuItem<String>(
                  value: 'off',
                  checked: !hasSelected,
                  child:
                      const Text('关闭字幕', style: TextStyle(fontSize: 12)),
                ),
              if (tracks.isEmpty)
                const PopupMenuItem<String>(
                  enabled: false,
                  child: Text('无可用字幕轨',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                )
              else
                ...tracks.map((t) => CheckedPopupMenuItem<String>(
                      value: 'sub:${t.id}',
                      checked: t.isSelected,
                      child: Text('💬 ${t.displayName}',
                          style: const TextStyle(fontSize: 12)),
                    )),
            ],
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
          child: PopupMenuButton<String>(
            tooltip: '',
            color: const Color(0xFF202028),
            onSelected: (value) => unawaited(
                _handleAudioSelected(value, tracks, nav)
                    .whenComplete(() => onSelectionHandled?.call())),
            child: rowBuilder?.call(tracks) ??
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Icon(Icons.audiotrack_rounded,
                      color: Colors.white, size: 20),
                ),
            itemBuilder: (ctx) => tracks.isEmpty
                ? const [
                    PopupMenuItem<String>(
                      enabled: false,
                      child: Text('无可用音轨',
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ),
                  ]
                : tracks
                    .map((t) => CheckedPopupMenuItem<String>(
                          value: 'audio:${t.id}',
                          checked: t.isSelected,
                          child: Text('🔊 ${t.displayName}',
                              style: const TextStyle(fontSize: 12)),
                        ))
                    .toList(),
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
          child: PopupMenuButton<String>(
            tooltip: '',
            color: const Color(0xFF202028),
            onSelected: (value) => unawaited(
                _handleVideoSelected(value, tracks, nav)
                    .whenComplete(() => onSelectionHandled?.call())),
            child: rowBuilder?.call(tracks, selectedId) ??
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Icon(Icons.video_settings_rounded,
                      color: Colors.white, size: 20),
                ),
            itemBuilder: (ctx) => [
              CheckedPopupMenuItem<String>(
                value: 'auto',
                checked: selectedId == 'auto',
                child: const Text('自动', style: TextStyle(fontSize: 12)),
              ),
              CheckedPopupMenuItem<String>(
                value: 'no',
                checked: selectedId == 'no',
                child: const Text('关闭', style: TextStyle(fontSize: 12)),
              ),
              ...tracks.map((t) => CheckedPopupMenuItem<String>(
                    value: 'video:${t.id}',
                    checked: selectedId == 'video:${t.id}',
                    child: Text('🎞 ${t.displayName}',
                        style: const TextStyle(fontSize: 12)),
                  )),
            ],
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
      child: PopupMenuButton<String>(
        tooltip: '',
        color: const Color(0xFF202028),
        onSelected: (value) => unawaited(
            _handleScaleSelected(value)
                .whenComplete(() => onSelectionHandled?.call())),
        child: rowBuilder?.call(currentLabel) ??
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Icon(Icons.aspect_ratio_rounded,
                  color: Colors.white, size: 20),
            ),
        itemBuilder: (ctx) => options
            .map((o) => CheckedPopupMenuItem<String>(
                  value: o.value,
                  checked: o.value == current,
                  child: Text(o.label, style: const TextStyle(fontSize: 12)),
                ))
            .toList(),
      ),
    );
  }

  Future<void> _handleSubtitleSelected(String value, List<TrackInfo> tracks,
      PlayerSubtitleTracksNav nav) async {
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
      _osdController.show(
          Icons.subtitles_rounded, '字幕: ${track.displayName}');
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

  Future<void> _handleVideoSelected(String value, List<TrackInfo> tracks,
      PlayerVideoTracksNav nav) async {
    try {
      final TrackInfo track;
      if (value == 'auto') {
        track = const TrackInfo(
            id: 'auto', type: TrackType.video, title: '自动');
      } else if (value == 'no') {
        track = const TrackInfo(
            id: 'no', type: TrackType.video, title: '关闭');
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
        content: const Text(
            '将还原当前影片的片头 / 片尾、播放器设置与画面比例为默认值。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重置', style: TextStyle(color: Color(0xFFE50914))),
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
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: const Color(0xFF40404C),
                    thumbColor: Colors.white,
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
    return IconButton(
      icon: Icon(
        icon,
        size: iconSize,
        color: enabled ? Colors.white : Colors.white38,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
      hoverColor: const Color(0x1FFFFFFF),
      onPressed: onPressed,
    );
  }
}
