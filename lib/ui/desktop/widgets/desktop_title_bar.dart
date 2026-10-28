import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';
import '../../theme/app_icon_assets.dart';
import '../../theme/app_palette.dart';
import 'focus_ring.dart';
import '../../theme/app_tokens.dart';

/// 标题栏高度：DesktopWindowFrame 顶部栏实高（窗口控制按钮与全局消息浮层定位共用）。
const double kDesktopTitleBarHeight = 44;

/// Netflix 风格自定义无边框窗口标题栏 (Desktop Title Bar)
///
/// 视觉特性：
/// 1. 左侧：品牌 Logo + 站源切换胶囊；
/// 2. 中间：可拖拽移动窗口区域；
/// 3. 右侧：Netflix 风格紧凑型搜索框（缩小为 240~260px，不再是全屏横栏）、搜索执行按钮、刷新按钮、设置与窗口控制组；
/// 4. 彻底移除旧版时间栏，布局极为紧凑沉浸。
class DesktopTitleBar extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final String? activeSiteName;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onSiteSelectorPressed;
  final Widget? searchBar;
  final VoidCallback? onRefresh;
  final bool refreshBusy;

  const DesktopTitleBar({
    super.key,
    required this.windowManager,
    this.activeSiteName,
    this.onSettingsPressed,
    this.onSiteSelectorPressed,
    this.searchBar,
    this.onRefresh,
    this.refreshBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      height: kDesktopTitleBarHeight,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(
          bottom: BorderSide(color: palette.divider, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),

          // 左侧 1：应用 Logo（单版圆角图标）
          Image.asset(
            appIconAsset,
            width: 26,
            height: 26,
            filterQuality: FilterQuality.high,
          ),
          const SizedBox(width: 10),

          // 左侧 2：站源切换按钮（直接展示当前站源名称，无多余前缀）
          _SiteSourcePill(
            siteName: activeSiteName ?? '选择站源',
            onTap: onSiteSelectorPressed,
          ),

          // 中间：拖拽移动区域（双击最大化/还原，拖拽移动窗口）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () => windowManager.toggleMaximize(),
              onPanStart: (_) => windowManager.startDragging(),
              child: Container(color: Colors.transparent),
            ),
          ),

          // 右侧 1：Netflix 风格紧凑型搜索框（缩小版，不再占据主内容区一行）
          if (searchBar != null) ...[
            searchBar!,
            const SizedBox(width: 8),
          ],

          // 右侧 2：刷新按钮（微透圆形图标按钮）
          if (onRefresh != null) ...[
            _TitleBarIconButton(
              icon: Icons.refresh_rounded,
              tooltip: '刷新站源内容',
              busy: refreshBusy,
              onPressed: onRefresh!,
            ),
            const SizedBox(width: 6),
          ],

          // 右侧 3：设置按钮 [ ⚙ ] 与窗口控制按钮组
          if (onSettingsPressed != null)
            _WindowButton(
              icon: Icons.settings_suggest_outlined,
              tooltip: '配置与设置',
              onPressed: onSettingsPressed!,
            ),

          ValueListenableBuilder<bool>(
            valueListenable: windowManager.isAlwaysOnTopNotifier,
            builder: (context, isPinned, _) {
              return _WindowButton(
                icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                iconColor: isPinned ? palette.accentInk : null,
                tooltip: isPinned ? '取消置顶' : '窗口置顶',
                onPressed: () => windowManager.toggleAlwaysOnTop(),
              );
            },
          ),

          _WindowButton(
            icon: Icons.minimize_rounded,
            tooltip: '最小化',
            onPressed: () => windowManager.minimize(),
          ),

          ValueListenableBuilder<bool>(
            valueListenable: windowManager.isMaximizedNotifier,
            builder: (context, isMax, _) {
              return _WindowButton(
                icon: isMax
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                tooltip: isMax ? '向下还原' : '最大化',
                onPressed: () => windowManager.toggleMaximize(),
              );
            },
          ),

          _WindowButton(
            icon: Icons.close_rounded,
            tooltip: '关闭',
            isCloseButton: true,
            onPressed: windowManager.onWindowClose,
          ),
        ],
      ),
    );
  }
}

/// 顶栏微透图标按钮（用于刷新等轻量操作）
class _TitleBarIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool busy;

  const _TitleBarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
  });

  @override
  State<_TitleBarIconButton> createState() => _TitleBarIconButtonState();
}

class _TitleBarIconButtonState extends State<_TitleBarIconButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: FocusRing(
        onTap: widget.busy ? () {} : widget.onPressed,
        semanticLabel: widget.tooltip,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor:
              widget.busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.busy ? null : widget.onPressed,
            child: AnimatedContainer(
              // 2026-10-27 实机反馈：hover **不做任何过渡**。
              // 移出要直接还原，而 200ms 的渐入 / 渐隐在实机上都被
              // 看成「闪一下」（快速扫过一排按钮时更明显）。
              duration: Duration.zero,
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isHovered
                    ? palette.hover
                    : Colors.white.withValues(alpha: 0.05),
                border: Border.all(
                  color: _isHovered
                      ? palette.accentInk
                      : context.glassBorder,
                  width: 0.8,
                ),
              ),
              child: Center(
                child: widget.busy
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(palette.accentInk),
                        ),
                      )
                    : Icon(
                        widget.icon,
                        size: 16,
                        color: _isHovered
                            ? palette.accentInk
                            : palette.textSub,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 首页站源胶囊按钮（直接显示站源名称）
class _SiteSourcePill extends StatefulWidget {
  final String siteName;
  final VoidCallback? onTap;

  const _SiteSourcePill({
    required this.siteName,
    this.onTap,
  });

  @override
  State<_SiteSourcePill> createState() => _SiteSourcePillState();
}

class _SiteSourcePillState extends State<_SiteSourcePill> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Duration.zero,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: _isHovered ? palette.hover : palette.raised,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: _isHovered ? palette.accentInk : palette.borderStrong,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.source_rounded, size: 14, color: palette.accentInk),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  widget.siteName,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    color: _isHovered ? palette.textTitle : palette.textBody,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 16,
                color: _isHovered ? palette.accentInk : palette.textSub,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一 Windows 按钮悬浮样式组件
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isCloseButton;
  final Color? iconColor;

  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isCloseButton = false,
    this.iconColor,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    Color backgroundColor = Colors.transparent;
    Color iconColor = widget.iconColor ?? palette.textBody;

    if (_isHovered) {
      if (widget.isCloseButton) {
        backgroundColor = const Color(0xFFE81123);
        iconColor = Colors.white;
      } else {
        backgroundColor = palette.hover;
        iconColor = palette.textTitle;
      }
    }

    return FocusRing(
      onTap: widget.onPressed,
      semanticLabel: widget.tooltip,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xs)),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            onTap: widget.onPressed,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: Duration.zero,
              width: 44,
              height: kDesktopTitleBarHeight,
              color: backgroundColor,
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 16,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
