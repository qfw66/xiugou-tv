import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/live/live_playback_mode.dart';
import '../../../core/player/models/player_state.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 直播页左上角「播放方式」胶囊的视图模型；文案、忙碌态、回调都由宿主装配。
class PlaybackModeNav {
  const PlaybackModeNav({
    required this.mode,
    required this.source,
    this.detail,
    required this.checked,
    this.busy = false,
    required this.onSelect,
  });

  /// 当前实际的播放方式。
  final PlaybackMode mode;
  final PlaybackModeSource source;

  /// 判定依据（如 `endlist`、`probe-timeout`），只用于展示。
  final String? detail;
  final LivePlaybackChoice checked;

  /// 正在读清单识别 / 重新起播。
  final bool busy;
  final ValueChanged<LivePlaybackChoice> onSelect;
}

/// 播放器顶栏左上角的「播放方式：自动 / 按点播 / 按直播」胶囊 + 下拉菜单。
class PlaybackModeBadge extends StatefulWidget {
  const PlaybackModeBadge({
    super.key,
    required this.nav,
    this.onMenuOpenChanged,
  });

  final PlaybackModeNav nav;

  /// 菜单开合通知（宿主用它暂停 / 恢复顶栏自动隐藏）。
  final ValueChanged<bool>? onMenuOpenChanged;

  @override
  State<PlaybackModeBadge> createState() => _PlaybackModeBadgeState();
}

class _PlaybackModeBadgeState extends State<PlaybackModeBadge> {
  static const Color _ink = Color(0xFFFFFFFF);
  static const Color _highlight = Color(0xFF94A3B8);

  final GlobalKey _anchorKey = GlobalKey();
  bool _hovered = false;
  bool _menuOpen = false;

  bool get _enabled => !widget.nav.busy;

  String get _modeText =>
      widget.nav.mode == PlaybackMode.vod ? '点播' : '直播';

  /// 判定依据（HLS 探测 / 播放方式决策的 reason 码）→ 菜单头里的一句话；
  /// 来源标签已说清楚的（manual / container 等）不再重复。
  static String? _reasonText(String? reason) {
    final code = reason?.trim() ?? '';
    if (code.startsWith('probe-http-')) {
      return '清单请求失败 HTTP ${code.substring('probe-http-'.length)}';
    }
    return switch (code) {
      'endlist' || 'playlist-type-vod' => '清单已完结',
      'event' || 'sliding-window' => '清单仍在更新',
      'long-window-unfinished' => '清单很长且未完结',
      'probe-timeout' => '识别超时',
      'probe-failed' || 'probe-invalid-content' || 'probe-invalid-url' =>
        '识别失败',
      'unknown' => '清单特征不明显',
      _ => null,
    };
  }

  Future<void> _openMenu() async {
    if (!_enabled || _menuOpen) return;
    final anchorContext = _anchorKey.currentContext;
    final renderBox = anchorContext?.findRenderObject();
    final overlay = anchorContext == null ? null : Overlay.maybeOf(anchorContext);
    if (renderBox is! RenderBox || overlay == null || !renderBox.hasSize) {
      return;
    }
    final topLeft = renderBox.localToGlobal(Offset.zero);
    final overlayBox = overlay.context.findRenderObject();
    final overlaySize =
        overlayBox is RenderBox ? overlayBox.size : MediaQuery.sizeOf(context);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy + renderBox.size.height + 8,
        renderBox.size.width,
        0,
      ),
      Offset.zero & overlaySize,
    );

    setState(() => _menuOpen = true);
    widget.onMenuOpenChanged?.call(true);
    LivePlaybackChoice? choice;
    try {
      choice = await showMenu<LivePlaybackChoice>(
        context: context,
        position: position,
        color: const Color(0xFF16161C),
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 280),
        items: _buildMenuItems(),
      );
    } finally {
      if (mounted) {
        setState(() => _menuOpen = false);
        widget.onMenuOpenChanged?.call(false);
      }
    }
    if (choice != null) widget.nav.onSelect(choice);
  }

  List<PopupMenuEntry<LivePlaybackChoice>> _buildMenuItems() {
    final nav = widget.nav;
    final detail = _reasonText(nav.detail);
    final current = '当前按$_modeText播放 · ${playbackModeSourceLabel(nav.source)}'
        '${detail == null ? '' : '（$detail）'}';
    return [
      PopupMenuItem<LivePlaybackChoice>(
        enabled: false,
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: _MenuHeader(current: current),
      ),
      for (final choice in LivePlaybackChoice.values)
        PopupMenuItem<LivePlaybackChoice>(
          key: ValueKey('playback-mode-${choice.name}'),
          value: choice,
          // 「自动」打勾时仍可点：等于重新识别一次。
          enabled: choice == LivePlaybackChoice.auto || choice != nav.checked,
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _ChoiceRow(choice: choice, checked: choice == nav.checked),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.nav.busy;
    final label = busy ? '识别中…' : '播放方式：$_modeText';
    return FocusRing(
      onTap: _enabled ? () => unawaited(_openMenu()) : null,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.pill)),
      semanticLabel: busy ? '正在识别播放方式' : '$label，点击切换',
      color: _ink,
      child: ExcludeSemantics(
        child: Tooltip(
          message: '播放方式：自动识别 / 按点播（可拖动）/ 按直播',
          waitDuration: const Duration(milliseconds: 400),
          child: MouseRegion(
            cursor:
                _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) {
              if (_enabled) setState(() => _hovered = true);
            },
            onExit: (_) {
              if (_hovered) setState(() => _hovered = false);
            },
            child: GestureDetector(
              key: _anchorKey,
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: _enabled ? () => unawaited(_openMenu()) : null,
              child: AnimatedContainer(
                key: const ValueKey('player-playback-mode-badge'),
                duration: AppMotion.exit,
                curve: AppMotion.ease,
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white
                      .withValues(alpha: (_hovered || _menuOpen) ? 0.16 : 0.10),
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadii.pill)),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          key: ValueKey('player-playback-mode-busy'),
                          strokeWidth: 1.8,
                          color: _ink,
                        ),
                      )
                    else
                      Icon(
                        widget.nav.mode == PlaybackMode.vod
                            ? Icons.slow_motion_video_rounded
                            : Icons.sensors_rounded,
                        size: 14,
                        color: _highlight,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      maxLines: 1,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!busy) ...[
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.expand_more_rounded,
                        size: 16,
                        color: _highlight,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '播放方式',
          style: TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: AppType.label,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          current,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: AppType.caption,
          ),
        ),
      ],
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.choice, required this.checked});

  final LivePlaybackChoice choice;
  final bool checked;

  (String, String) get _texts => switch (choice) {
        LivePlaybackChoice.auto => ('自动识别', '起播前只读清单（最多 4 秒）判定点播 / 直播'),
        LivePlaybackChoice.vod => ('按点播（可拖动）', '显示进度条，可以拖动'),
        LivePlaybackChoice.live => ('按直播', '不能拖动，按直播参数播放'),
      };

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = _texts;
    return Semantics(
      container: true,
      button: true,
      selected: checked,
      label: '$title，$subtitle${checked ? '，当前' : ''}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: AppType.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: AppType.caption,
                    ),
                  ),
                ],
              ),
            ),
            if (checked) ...[
              const SizedBox(width: 10),
              const Icon(Icons.check_rounded, size: 16, color: Color(0xFFFFFFFF)),
            ],
          ],
        ),
      ),
    );
  }
}
