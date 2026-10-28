import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 播放页右侧抽屉（§43 弹幕二期验收反馈：「播放设置」与「弹幕设置」都从右侧滑出）。
///
/// - 模态：点遮罩 / Esc / 面板里 `Navigator.pop` 都会收起（与原对话框同一套关闭语义，
///   所以面板内既有的「选完即关」逻辑不用改）；
/// - 贴右、整高，宽度 [width]（窗口过窄时不超过 85%）；
/// - 进出用横向滑动，时长沿用 [AppMotion]。
Future<T?> showPlayerSideDrawer<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double width = 340,
  String barrierLabel = '关闭',
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    // 遮罩固定压暗：无论深 / 浅主题，背后的视频都退到背景（与原播放设置对话框一致）。
    barrierColor: const Color(0x66000000),
    transitionDuration: AppMotion.enter,
    pageBuilder: (dialogContext, _, __) => LayoutBuilder(
      builder: (layoutContext, constraints) {
        final w = constraints.maxWidth * 0.85 < width
            ? constraints.maxWidth * 0.85
            : width;
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: w,
            height: constraints.maxHeight,
            child: Material(
              type: MaterialType.transparency,
              // 面板内行 hover 统一为主题前景 8%（默认主题 hover 在深底上几乎不可见）。
              child: Theme(
                data: Theme.of(dialogContext).copyWith(
                  hoverColor: AppPalette.of(dialogContext)
                      .playerText
                      .withValues(alpha: 0.08),
                ),
                child: Builder(builder: builder),
              ),
            ),
          ),
        );
      },
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(
              parent: animation,
              curve: AppMotion.ease,
              reverseCurve: AppMotion.ease.flipped)),
      child: child,
    ),
  );
}

/// 抽屉外框：深色半透明底 + 左侧细分隔线 + 头部（图标块、标题、关闭）+ 可滚动内容。
class PlayerSideDrawerFrame extends StatelessWidget {
  const PlayerSideDrawerFrame({
    super.key,
    required this.icon,
    required this.title,
    required this.closeTooltip,
    required this.child,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String closeTooltip;

  /// 内容（放在 [SingleChildScrollView] 里，超高可滚动）
  final Widget child;

  /// 固定在底部的附加内容（如「播放器」信息行）
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final divider = palette.playerText.withValues(alpha: 0.08);
    return Container(
      decoration: BoxDecoration(
        color: palette.playerChrome,
        border: Border(
          left: BorderSide(color: palette.playerText.withValues(alpha: 0.12)),
        ),
        boxShadow: const [
          // 投影固定黑色：浅色主题下也符合「浮在视频上」的直觉。
          BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(-8, 0)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                // 图标块 + 标题：与 B4 弹窗头部同一头部语言。
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: palette.raised,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Icon(icon, color: palette.accentInk, size: 16),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  title,
                  style: TextStyle(
                    color: palette.playerText,
                    fontSize: AppType.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: palette.playerText, size: 18),
                  tooltip: closeTooltip,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: divider),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: child,
            ),
          ),
          if (footer != null) ...[
            Divider(height: 1, thickness: 1, color: divider),
            footer!,
          ],
        ],
      ),
    );
  }
}
