import 'package:flutter/material.dart';
import '../../theme/app_icon_assets.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../widgets/focus_ring.dart';

/// 桌面端主界面沉浸式左侧导航栏（Infuse × Netflix 风格融合）。
///
/// 具备：
/// - Infuse 风格轻量通透底板与 1px 微高光边框；
/// - 顶部品牌图标微光标识；
/// - 紧凑优雅的垂直导航项与柔和悬停微光；
/// - 底部内嵌设置中心入口；
/// - 全量支持键盘/无障碍焦点环（FocusRing）。
class DesktopSidebar extends StatelessWidget {
  final VoidCallback onHistoryTap;
  final VoidCallback onLiveTap;
  final VoidCallback onPushTap;
  final VoidCallback onFavoritesTap;
  final VoidCallback onSettingsTap;

  const DesktopSidebar({
    super.key,
    required this.onHistoryTap,
    required this.onLiveTap,
    required this.onPushTap,
    required this.onFavoritesTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final glassBorder = context.glassBorder;

    return Container(
      width: 112,
      decoration: BoxDecoration(
        color: context.sidebarBackground,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: glassBorder, width: 1.0),
        boxShadow: AppShadows.subtleDepth(),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      child: Column(
        children: [
          // 顶部：品牌微标与应用名称
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    boxShadow: [
                      BoxShadow(
                        color: palette.accentInk.withValues(alpha: 0.15),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    appIconAsset,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '修狗TV',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.bold,
                    color: palette.textTitle,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),

          // 细微分割线
          Divider(
            color: palette.divider,
            height: 1,
            thickness: 0.8,
            indent: 8,
            endIndent: 8,
          ),
          const SizedBox(height: 12),

          // 核心导航项列表
          _SidebarNavItem(
            icon: Icons.history_rounded,
            label: '历史',
            tooltip: '播放历史 (断点续播)',
            onTap: onHistoryTap,
          ),
          const SizedBox(height: 8),

          _SidebarNavItem(
            icon: Icons.live_tv_rounded,
            label: '直播',
            tooltip: '电视直播 (频道选台)',
            onTap: onLiveTap,
          ),
          const SizedBox(height: 8),

          _SidebarNavItem(
            icon: Icons.send_rounded,
            label: '推送',
            tooltip: '直链推送与 WebDAV',
            onTap: onPushTap,
          ),
          const SizedBox(height: 8),

          _SidebarNavItem(
            icon: Icons.star_rounded,
            label: '收藏',
            tooltip: '我的收藏',
            onTap: onFavoritesTap,
          ),

          const Spacer(),

          // 底部：设置中心紧凑入口
          FocusRing(
            onTap: onSettingsTap,
            semanticLabel: '设置中心',
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.sm)),
            child: _SidebarSettingsButton(onTap: onSettingsTap),
          ),
        ],
      ),
    );
  }
}

/// 侧边栏单个导航项（Infuse 药丸微光 + 平滑缩放）
class _SidebarNavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  const _SidebarNavItem({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return FocusRing(
      onTap: widget.onTap,
      semanticLabel: widget.label,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadii.md)),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: AppMotion.base,
              curve: AppMotion.ease,
              width: double.infinity,
              height: 58,
              decoration: BoxDecoration(
                color: _isHovered ? palette.accentWash : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: _isHovered
                      ? palette.accentInk.withValues(alpha: 0.35)
                      : Colors.transparent,
                  width: 1.0,
                ),
                boxShadow: _isHovered
                    ? [
                        BoxShadow(
                          color: palette.accentInk.withValues(alpha: 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.icon,
                    size: 22,
                    color: _isHovered ? palette.accentInk : palette.textSub,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      fontWeight:
                          _isHovered ? FontWeight.bold : FontWeight.w500,
                      color: _isHovered ? palette.textTitle : palette.textBody,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部紧凑设置按钮
class _SidebarSettingsButton extends StatefulWidget {
  final VoidCallback onTap;

  const _SidebarSettingsButton({required this.onTap});

  @override
  State<_SidebarSettingsButton> createState() => _SidebarSettingsButtonState();
}

class _SidebarSettingsButtonState extends State<_SidebarSettingsButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.base,
          curve: AppMotion.ease,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: _isHovered ? palette.hover : palette.raised,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: _isHovered ? palette.borderStrong : palette.border,
              width: 1.0,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.settings_outlined,
                size: 15,
                color: _isHovered ? palette.accentInk : palette.textSub,
              ),
              const SizedBox(width: 5),
              Text(
                '设置',
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: FontWeight.w600,
                  color: _isHovered ? palette.textTitle : palette.textSub,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
