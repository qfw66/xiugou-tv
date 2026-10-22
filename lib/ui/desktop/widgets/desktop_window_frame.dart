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

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      // 画中画模式下隐藏自绘标题栏（无边框小窗）；其余结构不变。
      body: ValueListenableBuilder<bool>(
        valueListenable: windowManager.isPipNotifier,
        builder: (context, pip, _) => Stack(
          fit: StackFit.expand,
          children: [
            pip
                ? child
                : Column(
                    children: [
                      DesktopTitleBar(
                        windowManager: windowManager,
                        activeSiteName: activeSiteName,
                        onSettingsPressed: onSettingsPressed,
                        onSiteSelectorPressed: onSiteSelectorPressed,
                        searchBar: searchBar,
                        onRefresh: onRefresh,
                        refreshBusy: refreshBusy,
                      ),
                      Expanded(child: child),
                    ],
                  ),
            _WindowChromeSync(windowManager: windowManager),
          ],
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
