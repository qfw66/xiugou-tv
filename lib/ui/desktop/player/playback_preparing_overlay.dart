import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/player/playback_intent.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 播放页的「起播准备」覆盖层：解析播放地址期间盖在播放器上。
///
/// <p>设计依据（`ui-ux-pro-max` 检索命中）：
/// - `progressive-loading` —— 超过 1s 的等待用**稳定骨架**，不用长时间阻塞转圈；
/// - `loading-states` —— 近似瞬时的等待不要闪：进度条延迟 [_barDelay] 出现，
///   静态骨架（封面/片名/集号）则**立刻**可见；
/// - `tap-feedback-speed` / `input-latency` —— 点击后 100ms 内必须有视觉反馈；
/// - `error-feedback` + `escape-routes` —— 失败时就地给错误与「重试 / 返回」；
/// - `reduced-motion` —— 系统要求减弱动效时退化为静态条。
class PlaybackPreparingOverlay extends StatefulWidget {
  const PlaybackPreparingOverlay({
    super.key,
    required this.intent,
    this.onRetry,
    this.onCancel,
  });

  final PlaybackIntent intent;

  /// 失败态「重试」回调；为空时不显示该按钮。
  final VoidCallback? onRetry;

  /// 「返回」回调（退出准备态，回到列表）。
  final VoidCallback? onCancel;

  @override
  State<PlaybackPreparingOverlay> createState() =>
      _PlaybackPreparingOverlayState();
}

class _PlaybackPreparingOverlayState extends State<PlaybackPreparingOverlay> {
  /// 进度条延迟出现，避免「解析只用了 80ms」时闪一下。
  static const Duration _barDelay = Duration(milliseconds: 120);

  Timer? _barTimer;
  bool _showBar = false;

  @override
  void initState() {
    super.initState();
    _scheduleBar();
  }

  @override
  void didUpdateWidget(covariant PlaybackPreparingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // preparing -> failed 时收起进度条；回到 preparing 时重新计时。
    if (oldWidget.intent.isFailed != widget.intent.isFailed) {
      _barTimer?.cancel();
      _barTimer = null;
      _showBar = false;
      if (!widget.intent.isFailed) _scheduleBar();
    }
  }

  void _scheduleBar() {
    _barTimer = Timer(_barDelay, () {
      if (!mounted) return;
      setState(() => _showBar = true);
    });
  }

  @override
  void dispose() {
    _barTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final intent = widget.intent;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Positioned.fill(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: intent.isFailed
            ? '播放准备失败：${intent.error ?? ''}'
            : '正在准备播放：${intent.title}',
        child: ColoredBox(
          color: palette.background.withValues(alpha: 0.94),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _cover(palette),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    intent.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.heading,
                      fontWeight: FontWeight.w600,
                      color: palette.textTitle,
                    ),
                  ),
                  if (intent.subtitle != null && intent.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      intent.subtitle!,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: palette.textSub,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  if (intent.isFailed)
                    _failed(palette, intent.error ?? '播放解析失败，请稍后重试')
                  else
                    _preparing(palette, reduceMotion),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 固定尺寸封面位：预留空间避免内容跳动（CLS）。
  Widget _cover(AppPalette palette) {
    final cover = widget.intent.cover;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.lg),
      child: SizedBox(
        width: 96,
        height: 136,
        child: cover == null || cover.isEmpty
            ? ColoredBox(color: palette.raised)
            : Image.network(
                cover,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(color: palette.raised),
              ),
      ),
    );
  }

  Widget _preparing(AppPalette palette, bool reduceMotion) {
    // 减弱动效时用静态条（40% 宽的强调色），不跑不确定进度动画。
    final Widget bar = reduceMotion
        ? Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.4,
              child: ColoredBox(color: palette.accentInk),
            ),
          )
        : LinearProgressIndicator(
            minHeight: 3,
            backgroundColor: palette.divider,
            valueColor: AlwaysStoppedAnimation<Color>(palette.accentInk),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 180,
          height: 3,
          child: _showBar
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  child: bar,
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '正在准备播放…',
          style: TextStyle(fontSize: AppType.label, color: palette.textSub),
        ),
      ],
    );
  }

  Widget _failed(AppPalette palette, String error) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 28, color: palette.danger),
        const SizedBox(height: AppSpacing.sm),
        Text(
          error,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: AppType.body, color: palette.textMain),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onRetry != null)
              OutlinedButton(
                onPressed: widget.onRetry,
                child: const Text('重试'),
              ),
            if (widget.onRetry != null && widget.onCancel != null)
              const SizedBox(width: AppSpacing.sm),
            if (widget.onCancel != null)
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('返回'),
              ),
          ],
        ),
      ],
    );
  }
}
