import 'package:flutter/material.dart';

import '../../../core/api/models/vod_models.dart';
import '../../../core/api/rating_picker.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/app_message.dart';

/// 「评分盲开」入口：点一下 → 拉候选 → 按评分随机挑一部 → 直接打开详情。
///
/// 只负责交互与提示：候选从哪来（[loadCandidates]）、挑中后怎么打开（[onOpen]）
/// 都由调用方注入，复用站源现有的详情链路。加载中 / 无评分数据 / 网络失败
/// 一律给中文提示，不静默。
class RatingPickButton extends StatefulWidget {
  const RatingPickButton({
    super.key,
    required this.loadCandidates,
    required this.onOpen,
    this.picker,
  });

  /// 拉候选影片；抛错时按钮会提示失败原因。
  final Future<List<VodItem>> Function() loadCandidates;

  /// 打开挑中的影片（详情 / 播放沿用调用方既有链路）。
  final Future<void> Function(VodItem item) onOpen;

  /// 去重窗口与随机源；由调用方持有可跨多次点击记住「最近挑过哪几部」，
  /// 省略时按钮自建一个。
  final RatingPicker? picker;

  @override
  State<RatingPickButton> createState() => _RatingPickButtonState();
}

class _RatingPickButtonState extends State<RatingPickButton> {
  late final RatingPicker _picker = widget.picker ?? RatingPicker();

  /// 正在拉候选 / 挑片：这段时间内按钮显示「正在挑片…」并禁止重复点击。
  bool _busy = false;
  bool _isHovered = false;

  Future<void> _handleTap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final candidates = await widget.loadCandidates();
      if (!mounted) return;
      final pick = _picker.pick(candidates);
      if (pick == null) {
        showAppMessage(
          '评分盲开：这次没有拿到带评分的影片，稍后再试',
          type: AppMessageType.warning,
        );
        return;
      }
      showAppMessage('评分盲开：《${pick.item.name}》 ${pick.scoreText} 分');
      await widget.onOpen(pick.item);
    } catch (e) {
      if (!mounted) return;
      showAppMessage('评分盲开失败：$e', type: AppMessageType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final highlighted = _isHovered || _busy;
    return Tooltip(
      message: '按评分随机挑一部高评分影片，直接打开',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : _handleTap,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashFactory: AppMotion.reduced(context)
              ? NoSplash.splashFactory
              : Theme.of(context).splashFactory,
          onHover: (hovering) => setState(() => _isHovered = hovering),
          child: AnimatedContainer(
            duration: _isHovered ? AppMotion.enter : AppMotion.exit,
            curve: AppMotion.ease,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: highlighted ? palette.raised : palette.card,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(
                color: highlighted ? palette.accentInk : palette.borderStrong,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.accentInk,
                    ),
                  )
                else
                  Icon(Icons.casino_rounded,
                      size: 16, color: palette.accentInk),
                const SizedBox(width: 8),
                Text(
                  _busy ? '正在挑片…' : '评分盲开',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    color: highlighted ? palette.textTitle : palette.textMain,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
