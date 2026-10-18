import 'dart:async';
import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';

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
    return Container(
      height: 42.0,
      decoration: const BoxDecoration(
        color: Color(0xFF14141A),
        border: Border(
          bottom: BorderSide(color: Color(0xFF24242E), width: 1.0),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),

          // 左侧 1：应用 Logo 标签 Badge [ 影视TV ]
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF201216),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF5A1A22), width: 1),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.live_tv_rounded,
                  size: 15,
                  color: Color(0xFFE50914),
                ),
                SizedBox(width: 6),
                Text(
                  '影视TV',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
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
                iconColor: isPinned ? const Color(0xFFE50914) : null,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      margin: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2B2B3A), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.access_time_rounded,
            size: 13,
            color: Color(0xFF8C8CA0),
          ),
          const SizedBox(width: 6),
          Text(
            _formattedTime,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFFD4D4E0),
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
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _isHovered ? const Color(0xFF2C2C3A) : const Color(0xFF1E1E26),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _isHovered ? const Color(0xFFE50914) : const Color(0xFF323240),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.source_rounded, size: 14, color: Color(0xFFE50914)),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  widget.siteName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _isHovered ? Colors.white : const Color(0xFFCACAD8),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 16,
                color: _isHovered ? const Color(0xFFE50914) : const Color(0xFF888898),
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
    Color backgroundColor = Colors.transparent;
    Color iconColor = widget.iconColor ?? const Color(0xFFC8C8D0);

    if (_isHovered) {
      if (widget.isCloseButton) {
        backgroundColor = const Color(0xFFE81123);
        iconColor = Colors.white;
      } else {
        backgroundColor = const Color(0xFF2D2D36);
        iconColor = Colors.white;
      }
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: 42,
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
    );
  }
}
