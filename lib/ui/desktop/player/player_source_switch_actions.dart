import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';
import 'playback_source_nav.dart';

/// 错误与准备失败共用的主动换源动作；忙态仍提供取消出口。
class PlayerSourceSwitchActions extends StatelessWidget {
  const PlayerSourceSwitchActions({
    super.key,
    required this.nav,
    this.onPlayerChrome = false,
  });

  final PlayerSourceSwitchNav nav;
  final bool onPlayerChrome;

  @override
  Widget build(BuildContext context) {
    final status = nav.statusText?.trim();
    final foreground = onPlayerChrome ? context.palette.playerText : null;
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: foreground,
      disabledForegroundColor: foreground?.withValues(alpha: 0.5),
    );
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FocusOutline(
                radius: AppRadii.pill,
                child: TextButton.icon(
                  key: const ValueKey('player-source-search'),
                  style: buttonStyle,
                  onPressed: nav.enabled && !nav.busy ? nav.onSearch : null,
                  icon: nav.busy
                      ? SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
                        )
                      : const Icon(Icons.travel_explore_rounded, size: 18),
                  label: Text(nav.busy ? '正在查找…' : '换源继续播放'),
                ),
              ),
              if (nav.busy && nav.onCancel != null)
                FocusOutline(
                  radius: AppRadii.pill,
                  child: TextButton(
                    key: const ValueKey('player-source-cancel'),
                    style: buttonStyle,
                    onPressed: nav.onCancel,
                    child: const Text('取消查找'),
                  ),
                ),
            ],
          ),
          if (status != null && status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                status,
                style: TextStyle(
                  color: foreground?.withValues(alpha: 0.8) ?? context.palette.textSub,
                  fontSize: AppType.body,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
