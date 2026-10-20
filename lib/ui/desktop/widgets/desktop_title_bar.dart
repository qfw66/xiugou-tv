import 'dart:async';
import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';
import '../../theme/app_icon_assets.dart';
import '../../theme/app_palette.dart';
import 'focus_ring.dart';
import '../../theme/app_tokens.dart';

/// 标题栏高度：DesktopWindowFrame 顶部栏实高（窗口控制按钮与全局消息浮层定位共用）。
const double kDesktopTitleBarHeight = 42;

/// Windows 风格自定义无边框窗口标题栏
class DesktopTitleBar extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final String? activeSiteName;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onSiteSelectorPressed;

  const DesktopTitleBar({
    super.key,
    required this.windowManager,
    this.activeSiteName,
    this.onSettingsPressed,
    this.onSiteSelectorPressed,
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
          const SizedBox(width: 12),

          // 左侧 1：应用 Logo（单版圆角图标，不再随主题切换素材）
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

          // 右侧 1：北京时间实时显示 (yyyy/MM/dd 周几 HH:mm)
          const DesktopBeijingClock(),
          const SizedBox(width: 6),

          // 右侧 2：设置按钮 [ ⚙ ] 与窗口控制按钮组
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

/// 北京时间实时刷新组件 (yyyy/MM/dd 周几 HH:mm，UTC+8)
class DesktopBeijingClock extends StatefulWidget {
  const DesktopBeijingClock({super.key});

  @override
  State<DesktopBeijingClock> createState() => DesktopBeijingClockState();
}

class DesktopBeijingClockState extends State<DesktopBeijingClock> {
  Timer? _timer;
  String _formattedTime = '';

  @override
  void initState() {
    super.initState();
    _formattedTime = formatBeijingTime(DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        final newTime = formatBeijingTime(DateTime.now());
        if (newTime != _formattedTime) {
          setState(() {
            _formattedTime = newTime;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 格式化为北京时间字符串
  static String formatBeijingTime(DateTime dateTime) {
    // 换算为 UTC+8 时区
    final beijing = dateTime.toUtc().add(const Duration(hours: 8));
    final year = beijing.year.toString().padLeft(4, '0');
    final month = beijing.month.toString().padLeft(2, '0');
    final day = beijing.day.toString().padLeft(2, '0');
    final weekdayStr = getWeekdayCn(beijing.weekday);
    final hour = beijing.hour.toString().padLeft(2, '0');
    final minute = beijing.minute.toString().padLeft(2, '0');
    return '$year/$month/$day $weekdayStr $hour:$minute';
  }

  static String getWeekdayCn(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return '周一';
      case DateTime.tuesday:
        return '周二';
      case DateTime.wednesday:
        return '周三';
      case DateTime.thursday:
        return '周四';
      case DateTime.friday:
        return '周五';
      case DateTime.saturday:
        return '周六';
      case DateTime.sunday:
        return '周日';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      margin: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: palette.raised,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: palette.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.access_time_rounded,
            size: 13,
            color: palette.textSub,
          ),
          const SizedBox(width: 6),
          Text(
            _formattedTime,
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w500,
              color: palette.textBody,
              letterSpacing: 0.3,
            ),
          ),
        ],
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
          duration: AppMotion.base,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
        // Windows 关闭键的红色与主题无关，保持不变
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
                duration: AppMotion.base,
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
        ));
  }
}
