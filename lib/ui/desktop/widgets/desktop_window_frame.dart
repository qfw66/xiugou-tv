import 'package:flutter/material.dart';
import '../window/desktop_window_manager.dart';
import '../../theme/app_palette.dart';
import 'desktop_title_bar.dart';

class DesktopWindowFrame extends StatelessWidget {
  final DesktopWindowManager windowManager;
  final Widget child;
  final String? activeSiteName;
  final VoidCallback? onSettingsPressed;
  final VoidCallback? onSiteSelectorPressed;
  final Widget? searchBar;
  final VoidCallback? onRefresh;
  final bool refreshBusy;

  const DesktopWindowFrame({
    super.key,
    required this.windowManager,
    required this.child,
    this.activeSiteName,
    this.onSettingsPressed,
    this.onSiteSelectorPressed,
    this.searchBar,
    this.onRefresh,
    this.refreshBusy = false,
  });

  Widget _titleBar() => DesktopTitleBar(
        windowManager: windowManager,
        activeSiteName: activeSiteName,
        onSettingsPressed: onSettingsPressed,
        onSiteSelectorPressed: onSiteSelectorPressed,
        searchBar: searchBar,
        onRefresh: onRefresh,
        refreshBusy: refreshBusy,
      );

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
            return Stack(
              fit: StackFit.expand,
              children: [
                // 结构必须稳定：标题栏槽位恒为 Column 的第 0 个孩子、内容恒为第 1 个，
                // 否则隐藏标题栏时内容会被重新挂载（页面状态、弹窗、播放器全丢）。
                Column(
                  children: [
                    if (hideTitleBar) const SizedBox.shrink() else _titleBar(),
                    Expanded(child: child),
                  ],
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
