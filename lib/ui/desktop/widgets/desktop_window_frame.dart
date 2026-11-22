import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';
import '../../theme/app_palette.dart';
import 'desktop_title_bar.dart';
import 'media_title_bar.dart';

class DesktopWindowFrame extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final Widget child;
  final String? activeSiteName;
  final String? activeSiteIcon;
  final Map<String, String>? activeSiteHeaders;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onSiteSelectorPressed;
  final Widget? searchBar;
  final VoidCallback? onRefresh;
  final bool refreshBusy;
  final bool sidebarCollapsed;
  final VoidCallback? onSidebarToggle;
  final VoidCallback? onDetailBack;

  const DesktopWindowFrame({
    super.key,
    required this.windowManager,
    required this.child,
    this.activeSiteName,
    this.activeSiteIcon,
    this.activeSiteHeaders,
    this.onSettingsPressed,
    this.onSiteSelectorPressed,
    this.searchBar,
    this.onRefresh,
    this.refreshBusy = false,
    this.sidebarCollapsed = false,
    this.onSidebarToggle,
    this.onDetailBack,
  });

  static bool hasDetailBackButton(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DetailBackScope>()?.active ??
      false;

  Widget _titleBar() => DesktopTitleBar(
        windowManager: windowManager,
        activeSiteName: activeSiteName,
        activeSiteIcon: activeSiteIcon,
        activeSiteHeaders: activeSiteHeaders,
        onSettingsPressed: onSettingsPressed,
        onSiteSelectorPressed: onSiteSelectorPressed,
        searchBar: searchBar,
        onRefresh: onRefresh,
        refreshBusy: refreshBusy,
        sidebarCollapsed: sidebarCollapsed,
        onSidebarToggle: onSidebarToggle,
      );

  Widget _detailBar(VoidCallback onBack) {
    return MediaTitleBar(
      key: const ValueKey('detail-top-bar'),
      scope: 'detail',
      onBack: onBack,
      windowManager: windowManager,
      onTitleDoubleTap: windowManager.toggleMaximize,
      actions: [
        ValueListenableBuilder<bool>(
          valueListenable: windowManager.isAlwaysOnTopNotifier,
          builder: (_, pinned, _) => IconButton(
            tooltip: pinned ? '取消置顶' : '窗口置顶',
            icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 17, color: pinned ? AppPalette.dark.selectionInk : Colors.white),
            onPressed: windowManager.toggleAlwaysOnTop,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      body: ValueListenableBuilder<bool>(
        valueListenable: windowManager.isPipNotifier,
        builder: (context, pip, _) => ValueListenableBuilder<bool>(
          valueListenable: windowManager.isImmersiveNotifier,
          builder: (context, immersive, _) {
            // §38：PiP 与「沉浸播放」都隐藏自绘标题栏（无边框）。
            //
            // 沉浸期间**不再**用「顶部热区滑出标题栏」：浮出的标题栏正好压在
            // 播放页顶栏的返回按钮上，用户点不到返回（2026-10-27 实机反馈）。
            // 现在标题栏彻底不渲染，窗口三键与拖动由播放页顶栏接管。
            final hideTitleBar = pip || immersive;
            final detailBack = hideTitleBar ? null : onDetailBack;
            return Stack(
              fit: StackFit.expand,
              children: [
                // 固定内容槽位，切换普通顶栏、悬浮顶栏或沉浸模式时不重新挂载页面。
                Column(
                  children: [
                    if (!hideTitleBar && detailBack == null)
                      _titleBar()
                    else
                      const SizedBox.shrink(),
                    Expanded(child: _DetailBackScope(
                      active: detailBack != null, child: child,
                    )),
                  ],
                ),
                if (detailBack != null)
                  Positioned(
                    top: 0, left: 0, right: 0,
                    child: _detailBar(detailBack),
                  ),
                _WindowChromeSync(windowManager: windowManager),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 正文只在窗口没有接管返回时显示自己的按钮，独立弹窗仍可退出。
class _DetailBackScope extends InheritedWidget {
  const _DetailBackScope({required this.active, required super.child});
  final bool active;

  @override
  bool updateShouldNotify(_DetailBackScope oldWidget) => active != oldWidget.active;
}

/// 把当前主题的窗口底色同步给原生窗口（避免浅色下缩放窗口时闪黑边）。
class _WindowChromeSync extends StatefulWidget {
  final DesktopWindowManager windowManager;

  const _WindowChromeSync({required this.windowManager});

  @override
  State<_WindowChromeSync> createState() => _WindowChromeSyncState();
}

class _WindowChromeSyncState extends State<_WindowChromeSync> {
  Color? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final color = AppPalette.of(context).background;
    if (_applied != color) {
      _applied = color;
      widget.windowManager.applyBackgroundColor(color);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
